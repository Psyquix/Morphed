#!/usr/bin/env python3
"""The one serialization for every JSON document this repo publishes.

Each persisted document is written by one of two families: `jq` in the shell
steps, `json.dump` in the Python steps. They now agree byte-for-byte, because
these files are diffed by eye on the `website` and `data` branches, and a format
flip there shows up as a whole-file change with nothing behind it (it used to be
three formats: single-line manifests, jq-pretty archive manifests, an indent=1
seed copy).

The chosen shape is jq's own default output - 2-space indent, raw UTF-8 instead
of \\uXXXX escapes, LF, one trailing newline - so a step that already pipes
through `jq` needs no extra hop, and Python matches it exactly. Verified against
jq over the live configs/stable_build.json, state/patch_sources.json,
state/build_content_hashes.json, state/app_versions.json and a synthetic
document carrying non-ASCII, empty containers and mixed number forms.

Key order is the order the object already has; pass sort_keys=True where a
stable order is what keeps a bot commit to real changes only (state files whose
consumers diff them between runs).

Not for newline-delimited JSON: the notify queue is one compact record per line
(notify_queue.sh) - a record stream, not a document - and job-scratch projections
that only jq reads back through --slurpfile are left as their writer emits them.

CLI - re-serialize existing files in place (idempotent, prints what it rewrote):
    python3 .github/scripts/jsonfmt.py <file>...
Exits non-zero on unreadable input, never on "already canonical".
"""
import json
import sys

INDENT = 2


def dumps(obj, sort_keys=False):
    """The canonical text for <obj>, including the trailing newline."""
    return json.dumps(obj, indent=INDENT, ensure_ascii=False,
                      sort_keys=sort_keys) + "\n"


def write(path, obj, sort_keys=False):
    """Write <obj> to <path> in the canonical form; always LF."""
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        f.write(dumps(obj, sort_keys=sort_keys))


def normalize(path):
    """Rewrite an existing file canonically; True when its bytes changed.

    Read as bytes, so a CRLF file on a Windows checkout is detected (and fixed)
    instead of looking already-canonical through Python's newline translation.
    Existing key order is kept: sorting is a decision of the writer that owns the
    file, not of the serializer.
    """
    with open(str(path), "rb") as f:
        text = f.read().decode("utf-8")
    out = dumps(json.loads(text))
    if out == text:
        return False
    with open(str(path), "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    return True


def main(argv):
    if len(argv) < 2:
        print(f"usage: {argv[0]} <file>...", file=sys.stderr)
        return 2
    changed = 0
    for path in argv[1:]:
        try:
            if normalize(path):
                changed += 1
                print(f"reformatted {path}")
        except Exception as exc:  # unreadable/not JSON: say which file and stop
            print(f"jsonfmt: {path}: {exc}", file=sys.stderr)
            return 1
    print(f"{len(argv) - 1} file(s) checked, {changed} rewritten.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
