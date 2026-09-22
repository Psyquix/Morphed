#!/usr/bin/env python3
"""Generate release notes: patch groups first, then per-source patch release notes.

Output format:
    ### 🧩 <source> (<tag>)

        <App> v<version>
        ...

    ---
    ### ℹ️ <brand>-release-notes:
    <patch release body>
    ---
    ...
"""
import json
import os
import re
import urllib.request
from pathlib import Path


def load_json(path, default=None):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {path}: {e}")
    return default if default is not None else {}


def resolve_display_name(target_key, info):
    base_name = info.get("display_name") or target_key
    variant = (info.get("variant") or "").strip()
    sub_variant = (info.get("sub_variant") or "").strip()
    extras = []
    if variant and variant.lower() != "default":
        extras.append(variant)
    if sub_variant:
        extras.append(sub_variant)
    if extras:
        return f"{base_name} ({' - '.join(extras)})"
    return base_name


def brand_slug(info, source):
    brand = (info.get("brand") or "").strip()
    if brand:
        return re.sub(r"\s+", "-", brand.lower())
    repo = (source.split("/")[-1] if "/" in source else source).lower()
    repo = re.sub(r"[-_]patches$", "", repo)
    return repo or "patches"


def fetch_release_body(source, tag):
    """Fetch a patch source's GitHub release notes body. Returns None on failure."""
    if not source or not tag or "/" not in source:
        return None
    url = f"https://api.github.com/repos/{source}/releases/tags/{tag}"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "rvb-release-notes",
    }
    token = os.environ.get("GH_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
        body = (data.get("body") or "").strip()
        return body if body else None
    except Exception as e:
        print(f"Warning: could not fetch release notes for {source} {tag}: {e}")
        return None


def main():
    build_json_file = Path("build.json")
    build_dir = Path("build")

    build_info = load_json(build_json_file, {})

    # Discover actual files in build/
    built_files = []
    if build_dir.exists():
        built_files = [f.name for f in build_dir.iterdir() if f.is_file() and f.suffix.lower() in [".apk", ".zip"]]

    # Map target keys to patch groups
    # Group: patch_source -> { "source", "tag", "slug", "apps": { app_name: version } }
    patch_groups = {}

    for target_key, info in build_info.items():
        if not isinstance(info, dict):
            continue
        patches_source = info.get("patches_source") or ""
        patches_ref = info.get("patches") or ""
        changelog_url = (info.get("changelog") or "").strip()

        # Extract primary patch source and version tag
        primary_source = patches_source.split()[0] if patches_source else (patches_ref.split()[0].split("/")[0] if "/" in patches_ref else "Patched")

        # Determine patch version tag
        patch_tag = ""
        if changelog_url:
            first_url = changelog_url.split()[0]
            if "/tag/" in first_url:
                patch_tag = first_url.split("/tag/")[-1].strip("/")
            elif "/-/releases/" in first_url:
                patch_tag = first_url.split("/-/releases/")[-1].strip("/")
            elif "/releases/" in first_url:
                patch_tag = first_url.split("/releases/")[-1].strip("/")

        if not patch_tag and patches_ref:
            ref_part = re.sub(r"\.(mpp|jar|rvp|apk|zip)$", "", patches_ref.split()[0], flags=re.IGNORECASE)
            tag_match = re.search(r"v?\d+(\.\d+)+([.-][a-zA-Z0-9]+)*", ref_part)
            if tag_match:
                matched = tag_match.group(0)
                patch_tag = matched if matched.startswith("v") else f"v{matched}"

        if primary_source not in patch_groups:
            patch_groups[primary_source] = {
                "source": primary_source,
                "tag": patch_tag,
                "slug": brand_slug(info, primary_source),
                "apps": {}
            }

        # Only list apps that actually produced a file in build/
        display_name = resolve_display_name(target_key, info)
        version = info.get("version", "")
        file_prefix = info.get("name", "")
        prefix_lower = file_prefix.lower()
        built = any(
            fname.lower().startswith(prefix_lower + "-v") or fname.lower().startswith(prefix_lower + "-module-")
            for fname in built_files
        ) if prefix_lower else bool(built_files)
        if built:
            patch_groups[primary_source]["apps"][display_name] = version

    lines = []
    sorted_group_keys = sorted(patch_groups.keys())

    # Patches block first
    for gkey in sorted_group_keys:
        group = patch_groups[gkey]
        apps = group["apps"]
        if not apps:
            continue
        tag_str = f" ({group['tag']})" if group["tag"] else ""
        lines.append(f"### 🧩 {group['source']}{tag_str}")
        lines.append("")
        for app_name in sorted(apps.keys()):
            ver = apps[app_name]
            ver_str = f" v{ver}" if ver else ""
            lines.append(f"    {app_name}{ver_str}")
        lines.append("")

    # Release notes blocks underneath, separated
    notes_groups = [patch_groups[k] for k in sorted_group_keys if patch_groups[k]["apps"]]
    if notes_groups:
        lines.append("---")
        lines.append("")
        for i, group in enumerate(notes_groups):
            if i > 0:
                lines.append("---")
                lines.append("")
            lines.append(f"### ℹ️ {group['slug']}-release-notes:")
            lines.append("")
            body = fetch_release_body(group["source"], group["tag"])
            if body:
                lines.append(body)
            else:
                tag_hint = f" {group['tag']}" if group["tag"] else ""
                lines.append(f"_Release notes unavailable for {group['source']}{tag_hint}_")
            lines.append("")

    content = "\n".join(lines)
    with open("build.md", "w", encoding="utf-8") as f:
        f.write(content)

    print("Successfully generated build.md")


if __name__ == "__main__":
    main()
