#!/usr/bin/env bash
# Functional regression test for the effective-patch-set helpers in utils.sh
# (_abi_token_of_arch / _effective_patch_versions / _effective_arch_verdict /
# _table_has_version) and the version gate they feed.
#
# The CLI is stubbed by redefining patches_list / patches_list_versions after
# sourcing utils.sh, so the canned blobs below are the input the real
# morphe-desktop binary produces (captured from MorpheApp/morphe-desktop 1.18.1
# against ggYasin/ggyasin-morphe-patches v1.6.0). Every rule is asserted against a
# negative control too - a parser test that only checks the happy path passes when
# the parser returns nothing at all.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------- arch tokens
[[ "$(_abi_token_of_arch arm64-v8a)" == "ARM64_V8A" ]] || fail "arm64-v8a token"
[[ "$(_abi_token_of_arch arm-v7a)" == "ARMEABI_V7A" ]] || fail "arm-v7a token"
[[ "$(_abi_token_of_arch ARM64)" == "ARM64_V8A" ]] || fail "arm64 alias"
[[ "$(_abi_token_of_arch all)" == "" ]] || fail "all must have no ABI token"
[[ "$(_abi_token_of_arch all)" != "" ]] && fail "arch-token guard is vacuous"

# ---------------------------------------------------------------- stubs
LP_BLOB=''
LV_BLOB=''
patches_list() { printf '%s\n' "$LP_BLOB"; }
patches_list_versions() { printf '%s\n' "$LV_BLOB"; }
reset_cache() { __EFF_PATCH_VER_CACHE__=(); }

LP_BLOB=$(cat <<'BLOB'
INFO: Index: 2
Name: Fast Offline Games startup
Description: Stops the loading screen; keeps Firebase: off.
Enabled: false
Compatible packages:
	Package name: com.example.disabled
	Compatible versions:
		1.2.3
		1.2.0
	Version codes:
		1.2.3: ARM64_V8A=3327
		1.2.0: ARMEABI_V7A=3204

Index: 3
Name: Patch With Apostrophe's
Description: second
Enabled: false
Compatible packages:
	Package name: com.example.disabled
	Compatible versions:
		1.2.3

Index: 9
Name: Any Version Patch
Enabled: true
Compatible packages:
	Package name: com.example.disabled
	Compatible versions:
		Any

Index: 12
Name: Second Startup Patch
Description: another
Enabled: false
Compatible packages:
	Package name: com.example.disabled
	Compatible versions:
		1.2.3
	Version codes:
		1.2.3: X86_64=99
BLOB
)
PKG=com.example.disabled
SRC=MorpheApp/morphe-desktop

# ------------------------------------------------- named table (included-patches)
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" named "'Fast Offline Games startup'") ||
	fail "named table failed for a default-disabled patch (rc=$?)"
want=$'1.2.3\tARM64_V8A=3327\n1.2.0\tARMEABI_V7A=3204'
[[ "$got" == "$want" ]] || fail "named table pinned+codes: got [$got]"

# Negative control: the same parser must NOT invent a version for a name that is
# not in the bundle.
reset_cache
if _effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" named "'No Such Patch'" >/dev/null; then
	fail "an included-patches name absent from the bundle must yield no table"
fi

# A name with an apostrophe, quoted the way TOML double quotes do it.
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" named '"Patch With Apostrophe'\''s"') ||
	fail "apostrophe name lookup (rc=$?)"
[[ "$got" == "1.2.3	" ]] || fail "apostrophe name: got [$got]"

# A patch that declares no constraint surfaces as Any.
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" named "'Any Version Patch'") ||
	fail "Any lookup (rc=$?)"
[[ "$got" == "Any	" ]] || fail "Any patch: got [$got]"

# Two patches declaring the same version => two occurrences (the resolver ranks
# on that count), and each patch's annotation is carried by its own line.
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" named "'Fast Offline Games startup' 'Second Startup Patch'")
[[ "$(grep -c '^1\.2\.3' <<<"$got")" == "2" ]] || fail "occurrence count: got [$got]"
[[ "$(grep -c '^1\.2\.0' <<<"$got")" == "1" ]] || fail "second patch must not redeclare 1.2.0: got [$got]"

# ---------------------------------------------------------------- arch verdicts
table=$'1.2.3\tARM64_V8A=3327\n1.2.0\tARMEABI_V7A=3204'
vc=$(_effective_arch_verdict "$table" 1.2.3 arm64-v8a) || fail "1.2.3 must satisfy arm64"
[[ "$vc" == "3327" ]] || fail "1.2.3 pin: got [$vc]"
if _effective_arch_verdict "$table" 1.2.3 arm-v7a >/dev/null; then
	fail "1.2.3 annotates ARM64 only and must be refused for arm-v7a"
fi
vc=$(_effective_arch_verdict "$table" 1.2.0 arm-v7a) || fail "1.2.0 must satisfy arm-v7a"
[[ "$vc" == "3204" ]] || fail "1.2.0 pin: got [$vc]"
# An arch the bundle never mentions for a version the table does not know is never
# filtered (an unknown version is the gate's business, not the verdict's).
vc=$(_effective_arch_verdict "$table" 9.9.9 arm-v7a) || fail "unknown version must not be refused here"
[[ -z "$vc" ]] || fail "unknown version pin: got [$vc]"
# Unannotated versions are unconstrained: no pin, no filter, for any arch.
plain=$'8.23.0\t'
for a in arm64-v8a arm-v7a all x86_64; do
	vc=$(_effective_arch_verdict "$plain" 8.23.0 "$a") || fail "unannotated 8.23.0 refused for $a"
	[[ -z "$vc" ]] || fail "unannotated 8.23.0 pinned $vc for $a"
done
# Lowercase tokens (the shape some bundles print) match case-insensitively.
vc=$(_effective_arch_verdict $'1.0\tarm64-v8a=7' 1.0 arm64-v8a) || fail "lowercase token refused"
[[ "$vc" == "7" ]] || fail "lowercase token pin: got [$vc]"
# Conflicting codes for one arch: declared, so still buildable, but no pin.
vc=$(_effective_arch_verdict $'1.0\tARM64_V8A=7\n1.0\tARM64_V8A=8' 1.0 arm64-v8a) ||
	fail "ambiguous codes must not refuse the build"
[[ -z "$vc" ]] || fail "ambiguous code pinned $vc"
# Mixed occurrences (one annotated, one not) stay unconstrained.
vc=$(_effective_arch_verdict $'1.0\tARM64_V8A=7\n1.0\t' 1.0 arm-v7a) ||
	fail "mixed annotation must not refuse the other arch"
[[ -z "$vc" ]] || fail "mixed annotation pinned $vc"
# Different patches annotating different ABIs for one version: buildable on each of
# them, refused for an arch nobody declared, and each arch gets its own code.
multi=$'1.2.3\tARM64_V8A=3327\n1.2.0\tARMEABI_V7A=3204\n1.2.3\tX86_64=99'
vc=$(_effective_arch_verdict "$multi" 1.2.3 x86_64) || fail "1.2.3 must satisfy x86_64"
[[ "$vc" == "99" ]] || fail "1.2.3 x86_64 pin: got [$vc]"
if _effective_arch_verdict "$multi" 1.2.3 arm-v7a >/dev/null; then
	fail "1.2.3 declares no arm-v7a build across the two patches"
fi

# ------------------------------------------------------- default table (CLI set)
LV_BLOB=$'INFO: Package name: com.example.disabled\nMost common compatible versions:\n\t8.23.0 (1 patch)\n'
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp com.ninegag.android.app "$SRC" default) ||
	fail "default table (rc=$?)"
[[ "$got" == "8.23.0	" ]] || fail "default table: got [$got]"

LV_BLOB=$'1.95.100 [versionCodes: ARM64_V8A=701951010, ARMEABI_V7A=701951010] (3 patches)\n1.95.101 (7 patches)\n'
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp com.example "$SRC" default) || fail "codes parse (rc=$?)"
# The comma separators the CLI prints are normalized away: the second column is a
# space separated token list, and a code carrying punctuation would become the pin.
[[ "$(head -1 <<<"$got")" == $'1.95.100\tARM64_V8A=701951010 ARMEABI_V7A=701951010' ]] ||
	fail "default table codes: got [$got]"

# list-versions printing only a header line is the real OfflineGames shape: it
# answered, so it is NOT a "no listing" permissive case.
LV_BLOB='INFO:  '
reset_cache
if _effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" default >/dev/null; then
	fail "a listing with no version lines must report rc=2, not a table"
fi
# An empty listing is the permissive case.
LV_BLOB=''
reset_cache
if _effective_patch_versions cli.jar bundle.mpp "$PKG" "$SRC" default >/dev/null; then
	fail "an empty listing must report rc=1 (permissive), not a table"
fi

# ------------------------------------------------------------------ the gate
# The default set answers and names no version for this package (the real
# OfflineGames shape), so no permissive path may mask a wrong accept.
LV_BLOB='INFO:  '
reset_cache
has_compatible_patches cli.jar bundle.mpp "$PKG" 1.2.3 "$SRC" "'Fast Offline Games startup'" ||
	fail "gate rejected a version the included patch declares"
reset_cache
has_compatible_patches cli.jar bundle.mpp "$PKG" 9.9.9 "$SRC" "'Fast Offline Games startup'" &&
	fail "gate accepted a version no included patch declares"
# Without included-patches the CLI's own count is the whole story: a bundle whose
# default set says nothing about this package keeps its old skip.
reset_cache
has_compatible_patches cli.jar bundle.mpp "$PKG" 1.2.3 "$SRC" "" &&
	fail "gate must still skip when only default-disabled patches exist and none was named"
# A tool that cannot answer at all stays permissive (negative control: both stubs
# fail outright, so nothing is known about the version).
patches_list() { return 1; }
patches_list_versions() { return 1; }
reset_cache
has_compatible_patches cli.jar bundle.mpp "$PKG" 1.2.3 "$SRC" "" ||
	fail "a failing list-versions must stay permissive"
reset_cache
has_compatible_patches cli.jar bundle.mpp "$PKG" 1.2.3 "$SRC" "'Fast Offline Games startup'" ||
	fail "a failing listing must stay permissive even when names are configured"

# --------------------------------------------------------- names with whitespace
# Venus-Patches prints its Discord version as "348.10 - Stable" while the engine's
# version_f (and every cache filename) has the spaces removed. The table is keyed in
# that canonical form, so both sides still match - and its version codes are a COMMA
# separated list, which must not leak a trailing comma into a pinned versionCode.
LP_BLOB=$(printf '%s\n' \
	'INFO: Index: 0' \
	'Name: Read All' \
	'Enabled: true' \
	'Compatible packages:' \
	'	Package name: com.discord' \
	'	Compatible versions:' \
	'		348.10 - Stable' \
	'	Version codes:' \
	'		348.10 - Stable: ARM64_V8A=348010, ARMEABI_V7A=348010, X86_64=348010, X86=348010')
# restore the listing stubs (the permissive-gate case above broke them)
patches_list() { printf '%s\n' "$LP_BLOB"; }
patches_list_versions() { printf '%s\n' "$LV_BLOB"; }
# scope _patch_arch_verdict reads the way build_rv has it
cli_jar=cli.jar
patches_jar=bundle.mpp
pkg_name=com.discord
declare -A args=([included_patches]="'Read All'" [cli_source]="$SRC")
reset_cache
got=$(_effective_patch_versions cli.jar bundle.mpp com.discord "$SRC" named "'Read All'") ||
	fail "spaced-version named table (rc=$?)"
[[ "$got" == $'348.10-Stable\tARM64_V8A=348010 ARMEABI_V7A=348010 X86_64=348010 X86=348010' ]] ||
	fail "spaced version / comma codes table: got [$got]"
# The gate is handed build_rv's space-stripped version_f; a caller that kept the raw
# name must land in the same place.
reset_cache
has_compatible_patches cli.jar bundle.mpp com.discord "348.10-Stable" "$SRC" "'Read All'" ||
	fail "gate lost a spaced-version match (stripped target)"
LV_BLOB=$'INFO: Package name: com.discord\nMost common compatible versions:\n\t348.10 - Stable [versionCodes: ARM64_V8A=348010, ARMEABI_V7A=348010] (26 patches)\n'
reset_cache
has_compatible_patches cli.jar bundle.mpp com.discord "348.10 - Stable" "$SRC" "" ||
	fail "gate lost a spaced-version match (default table, raw target)"
# Every annotated ABI is seen, so no arch is refused and the pin is a bare number.
for a in arm64-v8a arm-v7a x86_64 x86; do
	reset_cache
	vc=$(_patch_arch_verdict "348.10-Stable" "$a") || fail "348.10 must declare $a too"
	[[ "$vc" == "348010" ]] || fail "348.10/$a pin must be 348010, got [$vc]"
done
reset_cache
if _patch_arch_verdict "348.10-Stable" mips > /dev/null 2>&1; then
	: # unmapped arch token: never filtered (there is nothing to compare)
else
	fail "an unmapped arch must not be refused by an annotation"
fi

# ---------------------------------------------------------------- _table_has_version
_table_has_version "$table" 1.2.3 || fail "table lookup missed a declared version"
_table_has_version "$table" v1.2.3 && fail "table lookup must not match a v-prefixed miss"
_table_has_version "$table" 9.9.9 && fail "table lookup invented a version"

# ----------------------------------------- build_rv's candidate decision (scope-based)
# _patch_arch_verdict / _candidate_arch_verdict read cli_jar, patches_jar, pkg_name and
# args from build_rv's dynamic scope, so the scope is set up here the way build_rv does.
cli_jar=cli.jar
patches_jar=bundle.mpp
pkg_name=$PKG
# restore the listing stubs (the permissive-gate case above broke them)
patches_list() { printf '%s\n' "$LP_BLOB"; }
patches_list_versions() { printf '%s\n' "$LV_BLOB"; }
declare -A args=([included_patches]="'House ad only' 'Fast startup'" [cli_source]="$SRC")
LP_BLOB=$(printf '%s\n' \
	'INFO: Index: 2' \
	'Name: House ad only' \
	'Enabled: false' \
	'Compatible packages:' \
	'	Package name: com.example.disabled' \
	'	Compatible versions:' \
	'		1.2.3' \
	'	Version codes:' \
	'		1.2.3: ARM64_V8A=3327' \
	'' \
	'Index: 3' \
	'Name: Fast startup' \
	'Enabled: false' \
	'Compatible packages:' \
	'	Package name: com.example.disabled' \
	'	Compatible versions:' \
	'		1.2.0' \
	'	Version codes:' \
	'		1.2.0: ARMEABI_V7A=3204')
LV_BLOB='INFO:  '
reset_cache

# The arm64 build of the two-candidate pool keeps 1.2.3 (arm64-only) and redirects
# 1.2.0 (no arm64 annotation) away, because a sibling candidate is viable.
[[ "$(_candidate_arch_verdict 1.2.3 arm64-v8a '1.2.3 1.2.0')" == "3327" ]] ||
	fail "1.2.3/arm64 must pin 3327"
if _candidate_arch_verdict 1.2.3 arm-v7a '1.2.3 1.2.0' > /dev/null; then
	fail "1.2.3/arm-v7a must redirect to the v7a candidate"
fi
[[ "$(_candidate_arch_verdict 1.2.0 arm-v7a '1.2.3 1.2.0')" == "3204" ]] ||
	fail "1.2.0/arm-v7a must pin 3204"
# With no sibling that mentions the arch, the annotation alone must not refuse the
# build: the bytes decide (docs/decisions/0009).
reset_cache
if ! _candidate_arch_verdict 1.2.3 arm-v7a "1.2.3" > /dev/null 2>&1; then
	fail "a lone arm64-only candidate must still be tried when nothing declares arm-v7a"
fi
# A single candidate with an unknown arch (all/auto) is never filtered.
[[ -z "$(_candidate_arch_verdict 1.2.3 all '1.2.3')" ]] || fail "arch=all must not pin or filter"

echo "PATCH VERSION HELPERS: PASS"
