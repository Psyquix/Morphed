#!/usr/bin/env python3
import sys
import re


def extract_versions(html_content: str, allow_all: bool = False) -> list[str]:
    # Restrict search to primary content / listWidget area to avoid scraping
    # sidebar widgets ("Popular in last 24 hours", trending apps, etc.)
    content_to_search = html_content
    m_primary = re.search(
        r'(?:id="primary"|class="[^"]*listWidget[^"]*")(.*)', html_content, re.DOTALL)
    if m_primary:
        content_to_search = m_primary.group(1)

    m_secondary = re.search(
        r'(?:id="secondary"|<aside\b|class="[^"]*sidebar[^"]*")', content_to_search, re.IGNORECASE)
    if m_secondary:
        content_to_search = content_to_search[:m_secondary.start()]

    # Extract links with class fontBlack pointing to releases
    links = re.findall(
        r'<a\s+[^>]*class="[^"]*fontBlack[^"]*"[^>]*href="([^"]*-release/)"[^>]*>(.*?)</a>', content_to_search, re.DOTALL)
    if not links:
        # Fallback in case attribute order differs
        links = re.findall(
            r'<a\s+[^>]*href="([^"]*-release/)"[^>]*class="[^"]*fontBlack[^"]*"[^>]*>(.*?)</a>', content_to_search, re.DOTALL)

    versions = []
    seen = set()
    for href, text in links:
        clean_text = re.sub(r'<[^>]+>', '', text).strip()
        if not clean_text:
            continue
        lower = clean_text.lower()
        if not allow_all and any(kw in lower for kw in ("beta", "alpha", "secondary")):
            continue

        m_ver = re.search(r'(\d+\.\d+.*)$', clean_text)
        ver = m_ver.group(1).strip() if m_ver else clean_text.split()[-1]
        if ver and ver not in seen:
            seen.add(ver)
            versions.append(ver)

    return versions


def extract_package_name(html_content: str) -> str | None:
    m = re.search(
        r'play\.google\.com/store/apps/details\?id=([a-zA-Z0-9_.]+)', html_content)
    if m:
        return m.group(1)
    m2 = re.search(
        r'id=([a-zA-Z0-9_.]+)"\s+class="[^"]*accent_color', html_content)
    if m2:
        return m2.group(1)
    return None


# Rows that carry every ABI: APKMirror prints them as 'universal' / 'noarch'.
UNRESTRICTED_ARCHES = ('universal', 'noarch')
# Rank for a 'Minimum Version' column we cannot read. Deliberately the LAST place a
# row can come: an unreadable column must lose to every row we can rank, never borrow
# a version number it does not have.
MINAPI_UNRANKED = 999999


def minapi_rank(node_min_ver: str) -> int:
    """APKMirror's 'Minimum Version' column as a sortable rank, lower = installs on
    an older device. 'Android 8.0+' -> 800, 'Android 4.0.3+' -> 400, 'Android 12L+'
    -> 1200 (the L suffix has no number of its own, so it ranks with 12)."""
    m = re.search(r'android\s*(\d+)(?:\.(\d+))?', (node_min_ver or '').lower())
    if not m:
        return MINAPI_UNRANKED
    return int(m.group(1)) * 100 + int(m.group(2) or 0)


def arch_class(node_arch: str, arch: str):
    """Can this row serve the requested arch, and how much of it does it cover?
    0 = covers more ABIs than asked for (one fetch serves several builds), 1 = exactly
    the requested ABI, None = unusable. A column listing several ABIs is matched by
    membership, not by whole-string equality against a hardcoded list of spellings -
    'arm64-v8a + armeabi-v7a + x86 + x86_64' carries arm-v7a just as the two-ABI form
    does. A catch-all request ('all', 'auto') may only take a row that carries
    everything."""
    a = (node_arch or '').strip().lower()
    if not a:
        return None
    if a in UNRESTRICTED_ARCHES:
        return 0
    b = (arch or '').strip().lower()
    if b in UNRESTRICTED_ARCHES or b in ('all', 'auto', ''):
        return None
    toks = [t.strip() for t in a.split('+') if t.strip()]
    if b not in toks:
        return None
    return 0 if len(toks) > 1 else 1


def apkmirror_search(html_content, dpi, arch, apk_bundle, clean_search_version, search_version, target_vc):
    """Pick the APKMirror variant row this build should download.

    Every predicate narrows the candidate set, then one ranking decides: the lowest
    'Minimum Version' wins, so the published artifact installs on the oldest device
    that can run the app rather than on the newest one listed. Fatter arch coverage
    breaks a tie (a multi-ABI row is one fetch for several builds), then an exact DPI
    match, then the row's place in the table.
    """
    dpi_str = dpi if dpi else "nodpi anydpi auto"
    appdpi = ["nodpi", "anydpi"]
    match_any_dpi = False
    if dpi_str:
        appdpi.extend(dpi_str.split())
        if "auto" in appdpi:
            match_any_dpi = True

    best_key = None
    best_url = ""

    # Split rows by table-row headerFont
    parts = re.split(
        r'<div class="[^"]*table-row[^"]*headerFont[^"]*"[^>]*>', html_content)
    if len(parts) <= 1:
        return None
    rows = parts[1:]

    # Reverse rows to match bash nth-last-child traversal order
    reversed_rows = list(reversed(rows))

    for idx, r in enumerate(reversed_rows):
        href_m = re.search(
            r'href="((?:https://www\.apkmirror\.com)?/apk/[^"]+)"', r)
        if not href_m:
            continue
        dlurl = href_m.group(1)
        if not dlurl.startswith("http"):
            dlurl = "https://www.apkmirror.com" + dlurl

        badge_m = re.search(
            r'class="[^"]*apkm-badge[^"]*"[^>]*>([^<]+)</span>', r)
        node_apk_bundle = badge_m.group(1).strip() if badge_m else "APK"

        cells = re.findall(
            r'<div class="table-cell[^"]*"[^>]*>(.*?)</div>', r, re.DOTALL)
        node_arch = re.sub(r'<[^>]+>', '', cells[1]
                           ).strip() if len(cells) > 1 else ""
        node_min_ver = re.sub(r'<[^>]+>', '', cells[2]
                              ).strip() if len(cells) > 2 else ""
        node_dpi = re.sub(r'<[^>]+>', '', cells[3]
                          ).strip() if len(cells) > 3 else ""

        node_vc = ""
        if len(cells) > 0:
            spans = re.findall(
                r'<span\s+class="([^"]*colorLightBlack[^"]*)"[^>]*>(.*?)</span>', cells[0], re.DOTALL)
            for cls, content in spans:
                if "dateyear_utc" in cls or "wrapText" in cls or "dateyear_utc" in content:
                    continue
                clean_txt = re.sub(r'<[^>]+>', '', content).strip()
                if clean_txt.isdigit():
                    node_vc = clean_txt
                    break
        if not node_vc:
            vc_m = re.search(
                r'class="colorLightBlack"[^>]*>([0-9]+)</span>', r)
            if not vc_m:
                vc_m = re.search(
                    r'span class="[^"]*colorLightBlack[^"]*"[^>]*>.*?([0-9]+).*?</span>', r, re.DOTALL)
            node_vc = vc_m.group(1).strip() if vc_m else ""

        if node_apk_bundle != apk_bundle:
            continue

        if clean_search_version:
            if clean_search_version not in dlurl and search_version not in dlurl:
                continue

        # A pinned versionCode is one more predicate on the row, not a licence to stop
        # looking: several variants share a versionCode and differ ONLY in arch, DPI and
        # minimum Android, so returning the first numeric hit hands an arm-v7a build the
        # arm64-only file (and the arch-honesty gate then drops the whole source).
        if target_vc:
            if not node_vc or node_vc != target_vc:
                continue

        a_class = arch_class(node_arch, arch)
        if a_class is None:
            continue
        if node_dpi in appdpi:
            d_class = 0
        elif match_any_dpi:
            d_class = 1
        else:
            continue

        key = (minapi_rank(node_min_ver), a_class, d_class, idx)
        if best_key is None or key < best_key:
            best_key = key
            best_url = dlurl

    return best_url or None


def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    subcmd = sys.argv[1]

    if subcmd == "vers":
        allow_all = (sys.argv[2].lower() == "true") if len(
            sys.argv) > 2 else False
        html_content = sys.stdin.read()
        vers = extract_versions(html_content, allow_all=allow_all)
        if vers:
            print("\n".join(vers))
            sys.exit(0)
        sys.exit(1)

    if subcmd == "pkg":
        html_content = sys.stdin.read()
        pkg = extract_package_name(html_content)
        if pkg:
            print(pkg)
            sys.exit(0)
        sys.exit(1)

    if len(sys.argv) < 7:
        sys.exit(1)

    dpi = sys.argv[1]
    arch = sys.argv[2]
    apk_bundle = sys.argv[3]
    clean_search_version = sys.argv[4]
    search_version = sys.argv[5]
    target_vc = sys.argv[6] if len(sys.argv) > 6 else ""

    html_content = sys.stdin.read()
    if not html_content:
        sys.exit(1)

    url = apkmirror_search(html_content, dpi, arch, apk_bundle,
                           clean_search_version, search_version, target_vc)
    if url:
        print(url)
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == '__main__':
    main()
