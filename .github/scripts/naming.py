"""Filename and catalog-name conventions — single source of truth.

Shared by .github/scripts/build_make_manifest.py and backfill_manifests.py.
IMPORTANT: this module is the one definition of those rules in the system. The
website's .github/scripts/rebuild_catalog.py imports this file at rebuild time (via a
sparse clone of main; see RVB_NAMING_DIR there) rather than keeping a copy, so a
change here takes effect on the site at the next catalogue rebuild and nowhere needs
to be "changed in both repos". Do not reintroduce a mirror: divergence between
builder and website parsing is the silent bug class the manifest architecture exists
to prevent. Keep this module stdlib-only so it stays importable from anywhere.

Manifest schema v1 (per-release build.json asset): see build_make_manifest.py.
"""
import re

_ARCH_TOKEN_RE = re.compile(
    r"-(arm64-v8a|armeabi-v7a|arm-v7a|aarch64|arm64|arm32|arm|x86_64|x64|x86|universal|all)(?:-(?:apk|module))?\.(?:apk|zip)$",
    re.IGNORECASE,
)
_FILE_PREFIX_RE = re.compile(r"^(.*?)-(?:v[0-9]|module-)", re.IGNORECASE)
# The version segment sits between the `-v`/`-module-v` marker and the trailing
# arch token; require a digit after `v` so a `-v` inside the prefix (e.g. the
# `-vpn` of `proton-vpn-...`) is never mistaken for the version start.
_VERSION_RE = re.compile(r"-(?:module-)?v(\d.*)$", re.IGNORECASE)


def normalize_key(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def normalize_arch(arch_raw):
    a = (arch_raw or "").lower().strip()
    if "arm64" in a or "aarch64" in a:
        return "arm64"
    if "arm" in a or "armeabi" in a:
        return "arm"
    if a in ["all", "universal"] or a.endswith("-all") or a.endswith("-universal"):
        return "all"
    if "x86_64" in a or "x64" in a:
        return "x86_64"
    if "x86" in a:
        return "x86"
    return a or "all"


def extract_arch(fname, version=""):
    """Best-effort architecture token from a build artifact filename.

    Tries known arch tokens, then the segment after the version if supplied,
    then the last hyphen-delimited segment before the extension.
    """
    match = _ARCH_TOKEN_RE.search(fname)
    if match:
        return match.group(1)
    if version:
        clean_ver = re.escape(version.lstrip("v"))
        m = re.search(
            rf"-v?{clean_ver}-([a-zA-Z0-9_-]+?)(?:-(?:apk|module))?\.(?:apk|zip)$", fname, re.IGNORECASE)
        if m:
            return m.group(1)
    name_no_ext = re.sub(r"\.(?:apk|zip)$", "", fname, flags=re.IGNORECASE)
    name_no_mode = re.sub(r"-(?:apk|module)$", "",
                          name_no_ext, flags=re.IGNORECASE)
    parts = name_no_mode.split("-")
    if len(parts) > 1:
        return parts[-1]
    return "all"


def file_prefix(fname):
    """`youtube-revanced-v19.16.39-arm64.apk` -> `youtube-revanced`.

    Returns the whole stem if nothing matches the -v/-module- shapes (e.g.
    fallback-synthesized names); callers treat it as the display prefix.
    """
    m = _FILE_PREFIX_RE.match(fname)
    return m.group(1) if m else fname.rsplit(".", 1)[0]


def extract_version(fname, hint=""):
    """App version token (no leading `v`) embedded in a build artifact filename.

    `inshorts-bholeykabhakt-v6.12.18-arm64-v8a.apk` -> `6.12.18`; a module
    `youtube-revanced-module-v19.16.39-arm64.zip` -> `19.16.39`. The filename is
    the authoritative per-arch version: a single build can publish arm64 at one
    version and arm at a fallback version, so callers must not trust a
    collapsed scalar. Strips the trailing arch+extension, then takes what
    follows the last `-v`/`-module-v` marker whose `v` is followed by a digit.
    Returns `hint` (leading `v` stripped) when the name carries no parseable
    version, else the empty string.
    """
    m = _ARCH_TOKEN_RE.search(fname)
    stem = fname[:m.start()] if m else re.sub(
        r"\.(?:apk|zip)$", "", fname, flags=re.IGNORECASE)
    mv = _VERSION_RE.search(stem)
    if mv:
        return mv.group(1)
    return (hint or "").lstrip("v")


def parse_patch_info(patches_source, patches_ref):
    """Derive (brand_key, brand_name) from the patch source repo, mirroring
    the old update_website_catalog.py behavior (owner-ish token after stripping
    'patches' affixes)."""
    primary = (patches_source or "").split()[0] if patches_source else ""
    if not primary and patches_ref:
        primary = patches_ref.split()[0].split("/")[0]

    primary_clean = primary.split(
        "/")[-1].replace("-patches", "").replace("patches-", "")
    primary_clean = primary_clean.split(
        "-")[0] if "-" in primary_clean else primary_clean
    primary_clean = primary_clean.capitalize(
    ) if primary_clean.islower() else primary_clean

    key = normalize_key(primary_clean) or "patched"
    name = primary_clean or "Patched"
    return key, name
