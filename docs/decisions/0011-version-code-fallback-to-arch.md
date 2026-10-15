# 0011 — A pinned version code is a preference; the arch wins when the bundle is wrong

**Status:** accepted (2026-10-15)
**Affects:** `scripts/utils.sh` (`dl_apkmirror`, the `build_rv` download loop),
`temp/failures/<slug>.json` (new `vc_fallback` field),
`.github/scripts/build_update_retry_list.sh`, `.github/scripts/build_report_failures.sh`.
Companion to [0007](0007-requested-arch-is-a-hard-requirement.md) (arch is hard) and
[0009](0009-effective-patch-set-decides-compatibility.md) (the effective patch set
decides compatibility).

## Context

A patch bundle annotates each app version with per-ABI version codes —
`[versionCodes: ARM64_V8A=…, ARMEABI_V7A=…]`. The engine reads that annotation, pins
the code for each arch, and the APKMirror variant picker then requires a row to match
**both** the pinned code **and** the requested arch (ADR 0007 makes the arch a hard
requirement).

That assumes the annotation is correct per ABI. It is not always.
`rushiranpise/morphe-patches` v1.23.0 lists MacroDroid 5.66.9 as
`ARMEABI_V7A=896600011` — but 896600011 is the **arm64** build; the real arm-v7a build
is **796600011**. The engine pinned 896600011 for the arm-v7a download, the only
variant carrying that code is arm64-only, the arch gate rejected it, and arm-v7a
failed — even though a matching-arch build of the same version existed on the store.
The failure was indistinguishable, in the report and to the retry queue, from an arch
that genuinely has no build.

The version code is a claim about *which build the patch was tested on*; the arch is a
claim about *what we are allowed to ship*. When they conflict because of a wrong
number, relaxing the arch would violate ADR 0007, but relaxing the (wrong) number is
safe.

## Decision

**A pinned version code is a preference, not a veto.**

- In `dl_apkmirror`, when no variant satisfies *code + arch*, retry selecting by
  **arch + version only**, dropping just the numeric code. The arch stays a hard
  requirement, so a universal or matching-ABI build is still the only thing accepted.
- When such a fallback yields a download, `build_rv` **re-keys** the artifact to the
  version code read off its bytes — renaming the staged APK and any sidecar and fixing
  `vc_infix` and the cache paths — so the cache filename, the release upload and the
  manifest all describe the bytes actually held. **Patch application becomes the real
  compatibility gate**: if the patch does not apply to the real build, the build fails
  honestly rather than shipping a mislabelled or unpatchable file.
- A failure that occurs *after* the fallback is terminal, not transient: the still-open
  `temp/failures/<slug>.json` is stamped `vc_fallback: true`; the retry writer parks it
  at the cap immediately (so it is not re-queued every run), and the failure report
  annotates the app as "version-code arch fallback already tried".

## Rejected alternatives

- **Trust the code strictly (status quo ante).** Fails a buildable arch whenever the
  bundle's per-ABI code is wrong, and the failure is indistinguishable from a genuine
  missing arch — so it also churns the retry queue until it parks.
- **Ship the code-matching variant under the requested arch's name.** Violates ADR 0007
  outright: it labels an arm64 file as arm-v7a.
- **Override the codes in the app TOML (`version-code = "arm-v7a: 796600011 | …"`).**
  Works, but is brittle — the codes change every release and it fixes exactly one app.
- **Fix it upstream only.** Correct in principle, but the builder cannot wait on a
  third-party repository, and the same authoring mistake recurs across bundles.

## Consequences

- The engine can now ship an arch whose build the bundle did not literally pin, gated
  by "the patch applies." A patch that is genuinely code-specific fails at apply time
  and is reported + parked, never silently shipped.
- `vc_fallback` is a new field on the build-failure record; both the report and the
  retry writer read it, so it must stay a boolean the descriptor can carry.
- Only the APKMirror source triggers the fallback — it is the source that lists
  per-ABI variants with their codes. Other sources still fail on a wrong code, which is
  acceptable because they do not carry the matching-arch build anyway.

## Verification

`scripts/apkmirror_search.py` on a two-variant fixture returns the 796600011 arm-v7a
href once the code is dropped, and the arm64 href unchanged when it is pinned. The
re-key rewrite, the immediate park on `vc_fallback`, and the report annotation are
covered by stubbed harnesses in `temp/`; the golden traces are unchanged. See
`.github/traces/README.md`.
