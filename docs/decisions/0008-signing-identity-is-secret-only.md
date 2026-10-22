# 0008 — The signing identity is a secret, never a repository file

**Status:** accepted (2026-10-08)
**Affects:** `scripts/utils.sh`, `scripts/build.sh`, `.github/scripts/install_keystore.sh`,
`.github/scripts/patchers.sh`, `ks.keystore` / `ks-p12.keystore` (deleted),
Actions secrets `KEYSTORE_B64` / `KEYSTORE_P12_B64` / `KEYSTORE_PASSWORD` / `KEY_ALIAS`,
every artifact published from this repository

## Context

This repo was forked from a template that committed its own `ks.keystore` (BKS) and
`ks-p12.keystore` (PKCS12), and `utils.sh` carried matching defaults
(`RVB_KEYSTORE_PASS=123456789`, `RVB_KEY_ALIAS=jhc`). `install_keystore.sh` treated
the secrets as optional: with none set it printed "using repo keystores" and carried
on. No `KEYSTORE_*` secret had ever been configured on this repository, so every
build up to 2026-10-08 was signed by a key whose private half is public, verified
from the deleted file: `CN=ReVanced`, SHA-256 `63:7C:22:6C…88:B4`. Anyone holding
the same template could hand a user a modified APK that installed over our builds as
a normal update. The docs already claimed the opposite ("the keystore is a CI secret
rather than a repository default"); nothing enforced it.

Two more identities were in play at the same time, quietly. The xposed flows handed
their patcher no keystore at all, so LSPatch signed Discord with the key bundled in
its own jar (password `123456`, alias `key0`) and NPatch would have used
`assets/npatch.key`. That made the signer a function of which patcher a config
named: switching toolchains silently changed it and broke in-place updates, which is
exactly what the 2026-10-08 switch of Discord from NPatch to LSPatch did.

## Decision

The signing identity exists only as four Actions secrets plus the maintainer's own
offline copy. Concretely:

- No keystore file is tracked, and `utils.sh` gives `RVB_KEYSTORE`, `RVB_KEYSTORE_P12`,
  `RVB_KEYSTORE_PASS`, `RVB_KEY_ALIAS` no default.
- `build.sh` calls `require_signing_identity` before the first download; it names
  each unset variable, checks both store files exist, and rejects a password or
  alias that could not survive the `eval`'d CLI arguments (alphanumeric password).
- `install_keystore.sh` fails the run when any secret is missing, instead of
  degrading to a fallback key.
- One key pair is held in both formats, under one alias and one password (the engine
  has a single password variable and passes it as both store and key password),
  because the consumers are not interchangeable: ReVanced CLI and Morphe read the
  BKS store, apksigner and LSPatch read the PKCS12 one, NPatch reads BKS and is the
  only consumer that needs the provider installed in the JVM.
- The xposed flows receive the identity the same way: the registry declares
  `PATCHER_KEYSTORE_FORMAT` and `patch_apk` passes `-k <store> <pass> <alias> <pass>`,
  so a patcher change cannot change the signer.
- A keystore, path or password never appears in `configs/**`: the `data` branch is
  public, and `patcher-args` is published with it.

## Rejected alternatives

- **Keep the template keystore.** It works, and it is the reason this record exists:
  the private key is public and shared by every fork.
- **Warn and continue when the secrets are absent.** The failure mode we removed. A
  run that silently signs with a fallback key looks green, ships artifacts, and the
  damage surfaces months later as an unfixable update conflict or a spoofed release.
  Rule 3 of `AGENTS.md` covers this: a default that asserts a value is a bug.
- **One PKCS12 store for everything.** Blocked: `app.revanced.library.ApkSigner`
  calls `KeyStore.getInstance("BKS", "BC")` with no format conversion anywhere in the
  jar, so `ReVanced/revanced-cli` apps (Aunali321, instagram, telegram) need a BKS
  store. Morphe would accept PKCS12 (it has `KeystoreImporter` + `KeystoreInputFormat
  {BKS,JKS,PKCS12}`), so the constraint is the stricter consumer, not the flow.
- **Derive the BKS store from the PKCS12 one at build time.** Feasible, since the
  runner installs BouncyCastle exactly on NPatch runs. Rejected as machinery on the
  signing path for the benefit of one fewer secret, with a new way to produce a
  mismatched signature mid-run.
- **Pass `-k` / `--keystore` from config.** Puts a keystore path and, in practice, a
  password onto a public branch.

## Consequences

Adopting a new identity costs one user-visible break: every previously installed
patched app has to be uninstalled, because its signer changed (announced
2026-10-08; builds 260211/260212 onward, Discord from 260213). Local builds need the
four variables exported, documented in
[contributing.md](../contributing.md#local-setup).

A known gap, deliberately left open: nothing verifies that the BKS and PKCS12
secrets hold the *same* key. `install_keystore.sh` checks the BKS magic and that the
alias is readable in the PKCS12 store, but reading BKS needs the provider, which is
only installed on NPatch runs. A rotation that updates one secret and not the other
would therefore split the signer between flows. The recovery is to re-run a build
and compare `apksigner verify --print-certs` output across one CLI-built and one
xposed-built artifact.

## Verification

- `.github/traces/goldens/*.trace` assert the argv: `--keystore=… --signer=…` on the
  cli-patch fixtures, `-k <store>` with the BKS store on the npatch fixtures and the
  PKCS12 store on the lspatch fixture, and no keystore argument on instafel.
- `bash .github/traces/trace_runner.sh verify` after any change to these paths.
- `bash scripts/build.sh <config>` with the variables unset must abort before any
  download; `install_keystore.sh` must exit non-zero on a missing secret, a wrong
  alias, a wrong password, and a non-BKS `KEYSTORE_B64` (harness kept at
  `temp/_identity_negatives.sh`).
- On a published artifact: `java -jar bin/apksigner.jar verify --print-certs <apk>`
  must show the maintainer certificate, not `CN=ReVanced` and not a patcher default.
