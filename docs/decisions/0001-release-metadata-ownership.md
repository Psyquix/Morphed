# 0001 — Release metadata is owned by whoever names it

**Status:** accepted (2026-09-29)
**Affects:** `.github/scripts/build_upload_release.sh`, `.github/workflows/build.yml`,
the `stable` and `beta` archive releases

## Context

`gh release edit` replaces a release's **whole** title and body — there is no
merge, no "patch this field". The uploader therefore had to decide, on every run,
which fields it owned. It did so with defaults:

```bash
TITLE="${RELEASE_TITLE:-${TITLE:-Build No. $TAG}}"   # never unset
IS_PRERELEASE="${IS_PRERELEASE:-false}"              # unset collapsed to false
NOTES_ARG=(-n "")                                    # nothing named ⇒ clear the body
```

That conflates *"the caller said nothing"* with *"the caller said empty/false"*.
Two consequences, both real:

- Every build rewrote the `stable`/`beta` release body to a boilerplate string,
  erasing hand-written notes, and forced both archives to non-prerelease — which
  is why the beta archive, whose files come from pre-release builds, carried no
  badge.
- A zero-byte `build.md` (a failed `generate_release_notes.py`) would have
  *cleared* a release body rather than left it alone.

An interim fix added a boolean, `UPDATE_EXISTING_METADATA=false`, to stop the
archive step writing prose. It worked, but it was a knob compensating for the
default rather than removing it — one flag per field meant the same bug
re-appearing for the next field anyone added.

## Decision

**One rule for every metadata field: a field the caller did not name is not
written.** Absence means "leave it be", never "write empty".

- Each field becomes a flag list that is empty unless named; the lists are joined
  into a single `gh release edit`, and when the result is empty **no call is made
  at all**.
- `IS_PRERELEASE` is tri-state (`true` / `false` / unset) and a fourth value is
  rejected with `::error::` + exit 2 rather than guessed at.
- `RELEASE_BODY_FILE` wins over `RELEASE_NOTES`; a missing or zero-byte body file
  counts as unnamed.
- CI's archive upload step names **no** metadata. It is a pure asset uploader.
- On create, gh's own defaults fill the gaps (release name = tag, empty body), so
  a seed value can only ever reach a release that did not exist yet.

## Rejected alternatives

- **Keep `UPDATE_EXISTING_METADATA`.** A per-field override of a bad default; the
  default was the bug. Removing it made the archive step's intent shorter to read.
- **An explicit `OVERWRITE` switch that also gates `--clobber`.** Metadata can
  express absence (don't name the field); assets cannot — the file list *is* the
  named intent, and `gh release upload` refuses a name the release already has.
  Making clobber opt-in would turn every retried run into a hard failure on the
  file it had already pushed, defeating the per-file retry. If protection against
  *replacing a file with different bytes* is ever needed, that is a content rule
  (compare checksums), not an overwrite toggle.
- **Re-asserting `IS_PRERELEASE` on the archives each build.** The flag is
  persistent state on the release, not a per-build output; re-asserting it bought
  nothing once a manual edit survives, and it kept the pipeline in charge of a
  field a human owns.

## Consequences

- Release pages for `stable`/`beta` are now genuinely owner-editable: title,
  notes and badge survive any number of builds.
- **CI no longer self-heals them.** If someone unticks "pre-release" on beta, or
  an archive release is deleted, the next build will not restore the state — it
  recreates the release as a full release with an empty body. `cleanup.yml` keeps
  both tags alive via `releases_keep_keyword: stable/beta`, so that is a
  manual-delete scenario.
- Recovery is one command each, and the archive step's comment says so:
  `gh release edit beta --prerelease`, plus a `--notes-file` re-upload for the body.
- Ad-hoc invocations of the uploader now cannot demote a release by forgetting a
  variable, which was the nastiest property of the old default (silent, and only
  visible on the release page).

## Verification

`temp/_metastop/test_metadata_write.sh` — stubbed `gh`, walks exists/create ×
title-named-or-not × notes-source × prerelease-state, and asserts which flags
actually reach `gh release edit`/`create`. The explicit `true`/`false` cases are
the negative controls for every absence assertion. Related invariants live in
[../ci-pipelines.md](../ci-pipelines.md) (step order) and
[../storage-and-branches.md](../storage-and-branches.md) (release table).
