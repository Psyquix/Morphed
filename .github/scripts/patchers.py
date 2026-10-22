#!/usr/bin/env python3
"""Patcher tool classification — CI-side mirror of .github/scripts/patchers.sh.

Single place where a cli-source repo string maps to a tool kind, so the CI
scripts and the build.yml BKS check can't drift from the engine's registry.
The tables must stay in sync with patchers.sh (same case rules); the engine
reads that file, CI reads this one. Divergence here = the bug class P1 removes.

Kinds: revanced | morphe | xposed | instafel | generic  (see patchers.sh).

CLI:
    patchers.py kind <cli-source>            # print kind
    patchers.py needs-bks <config.json>      # exit 0 if any enabled app needs BouncyCastle
    patchers.py bundle-globs <kind>          # print shell globs for patch bundles
"""
import fnmatch
import json
import sys

# Mirrors patchers.sh resolve_patcher(); keep both in sync.
_SUBSTR_KINDS = [
    # (lowercase substring patterns -> kind); first match wins, same order as shell case
    (("npatch", "lspatch"), "xposed"),
    (("instafel",), "instafel"),
    (("morphe-desktop",), "morphe"),
    (("revanced-cli",), "revanced"),
]

BUNDLE_GLOBS = {
    "xposed": ["*.apk"],
    "instafel": ["*.mpp", "*.rvp", "*.jar"],   # instafel core ships as *.jar
    "morphe": ["*.mpp", "*.rvp", "*.jar"],
    "revanced": ["*.mpp", "*.rvp", "*.jar"],
    "generic": ["*.mpp", "*.rvp", "*.jar"],
}

# Needs BouncyCastle (BKS keystores) in the runner — matches patchers.sh
# PATCHER_NEEDS_BKS. Within the xposed flow only NPatch qualifies: it calls
# KeyStore.getInstance("BKS") before choosing a keystore and ships its built-in
# keystores as BKS files, while JingMatrix LSPatch reads a bundled JKS through
# KeyStore.getDefaultType() and needs no provider at all.
NEEDS_BKS_SUBSTRINGS = ("npatch",)


def classify(cli_source: str) -> str:
    c = (cli_source or "").lower()
    for patterns, kind in _SUBSTR_KINDS:
        if any(p in c for p in patterns):
            return kind
    return "generic"


def needs_bks(cli_source: str) -> bool:
    """Would patching with this tool hit a BKS keystore request?"""
    c = (cli_source or "").lower()
    return classify(c) == "xposed" and any(p in c for p in NEEDS_BKS_SUBSTRINGS)


def ci_bundle_diffable(cli_sources) -> bool:
    """Preserves ci_check_app_patches.py's existing rule verbatim: a repo with
    no known cli is treated diffable; otherwise any cli-source containing
    'revanced' or 'morphe'. Note this is DELIBERATELY broader than classify():
    CI 'diffable' gates bundle-hash checking, the engine flag gates runtime
    behavior; do not "unify" them without deciding the semantics."""
    if not cli_sources:
        return True
    return any("revanced" in c or "morphe" in c for c in cli_sources)


def config_needs_bks(config_path: str) -> bool:
    with open(config_path, encoding="utf-8") as f:
        data = json.load(f)
    # Keys written before the first table header are file-level defaults, and the
    # engine inherits them into every table (build.sh DEF_CLI_SRC, then
    # `toml_get "$t" cli-source`). yq renders them as top-level *scalar* entries
    # sitting beside the tables, so a check that only reads a table's own
    # cli-source sees an Xposed app as `generic` and skips the BouncyCastle
    # install the app then dies on (`BKS not found`). Read the defaults here the
    # same way the engine does.
    defaults = {k: v for k, v in data.items() if not isinstance(v, dict)}
    for entry in data.values():
        # A table with no `enabled` key is enabled: build.sh does
        # `enabled=$(toml_get "$t" enabled) || enabled=true`. Only an explicit
        # false skips the app.
        if not isinstance(entry, dict) or entry.get("enabled") is False:
            continue
        cli = entry.get("cli-source", defaults.get("cli-source"))
        if isinstance(cli, str) and needs_bks(cli):
            return True
    return False


def _matches_any(name: str, globs) -> bool:
    return any(fnmatch.fnmatch(name.lower(), g.lower()) for g in globs)


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "kind" and len(argv) == 3:
        print(classify(argv[2]))
        return 0
    if cmd == "needs-bks" and len(argv) == 3:
        return 0 if config_needs_bks(argv[2]) else 1
    if cmd == "bundle-globs" and len(argv) == 3:
        print(" ".join(BUNDLE_GLOBS.get(argv[2], BUNDLE_GLOBS["generic"])))
        return 0
    print(f"unknown invocation: {' '.join(argv[1:])}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
