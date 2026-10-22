#!/usr/bin/env bash
set -euo pipefail

# Materialize the maintainer signing identity for this build from CI secrets.
#
# There is deliberately no fallback. This repo used to carry ks.keystore /
# ks-p12.keystore inherited from the template it was forked from and silently use
# them when the secrets were absent - which means a missing secret signed the run
# with a key whose private half is public, and anyone holding the same template
# could then publish signature-compatible "updates" over these builds. A default
# that asserts an identity is exactly what docs/decisions/0001 says not to guess.
#
# KEYSTORE_B64        base64 of the BKS keystore handed to the patch CLIs and NPatch
# KEYSTORE_P12_B64    base64 of the PKCS12 keystore used by apksigner and LSPatch
# KEYSTORE_PASSWORD   password of both stores; the engine has one password var and
#                     passes it as both store and key password, so they must match
# KEY_ALIAS           alias present in both stores, both holding the SAME key pair
#
# The files are written to the repo root and the four RVB_* vars are exported, so
# the engine never has to guess where the identity came from.

missing=
for v in KEYSTORE_B64 KEYSTORE_P12_B64 KEYSTORE_PASSWORD KEY_ALIAS; do
	[ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
	echo "::error::missing Actions secret(s):$missing - refusing to sign with the template keystore." >&2
	exit 1
fi

umask 077
printf '%s' "$KEYSTORE_B64" | base64 -d > ks.keystore
printf '%s' "$KEYSTORE_P12_B64" | base64 -d > ks-p12.keystore

# Catch a wrong secret here rather than at the first patch of every app.
# The BKS store is checked by its format magic, not through JCA: the BouncyCastle
# provider is only installed on runs that actually use NPatch, so keytool could
# not read BKS on an LSPatch-only config. BKS v2 starts with a 0x00000002 version
# int, BKS v1 with the literal "BKS-".
bks_magic=$(od -An -tx1 -N4 ks.keystore | tr -d ' \n')
case "$bks_magic" in
	00000002 | 424b532d) echo "[+] ks.keystore is a BouncyCastle keystore (magic $bks_magic)." ;;
	*)
		echo "::error::ks.keystore is not a BKS keystore (magic $bks_magic) - the patch CLIs and NPatch ask JCA for type BKS." >&2
		exit 1
	;;
esac

if command -v keytool >/dev/null 2>&1; then
	if keytool -list -keystore ks-p12.keystore -storetype PKCS12 \
		-storepass "$KEYSTORE_PASSWORD" -alias "$KEY_ALIAS" >/dev/null 2>&1; then
		echo "[+] ks-p12.keystore is PKCS12 and holds alias '$KEY_ALIAS'."
	else
		echo "::error::alias '$KEY_ALIAS' is not readable in ks-p12.keystore - KEYSTORE_PASSWORD or KEY_ALIAS does not match this keystore." >&2
		exit 1
	fi
else
	echo "[!] no keytool on PATH - skipped the PKCS12 alias check."
fi

echo "[+] installed ks.keystore ($(stat -c%s ks.keystore) bytes) and ks-p12.keystore ($(stat -c%s ks-p12.keystore) bytes)"

{
	echo "RVB_KEYSTORE=ks.keystore"
	echo "RVB_KEYSTORE_P12=ks-p12.keystore"
	echo "RVB_KEYSTORE_PASS=$KEYSTORE_PASSWORD"
	echo "RVB_KEY_ALIAS=$KEY_ALIAS"
} >>"$GITHUB_ENV"
echo "[+] signing identity exported (alias: $KEY_ALIAS)."
