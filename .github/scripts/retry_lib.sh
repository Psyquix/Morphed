#!/bin/bash
# retry_lib.sh — shared helpers for the config-change / failed-build pending list
# (ADR 0010). Sourced, never executed, by ci_detect_config_changes.sh (watcher)
# and build_update_retry_list.sh (build job). Stdlib shell + jq only.
#
# The two state files live on the `data` branch as regenerable state/*.json, so
# fetch_data_branch.sh / commit_data_branch.sh move them with no change of their
# own. Neither file is authored by hand: they are seeded and rewritten by these
# scripts, and a missing or corrupt one is treated as EMPTY (a no-op), never as
# "enable everything" - the same fail-safe direction as a blocked-source read.

# jqx <jq-args...> — jq with any stray carriage return stripped from the output.
# Git-Bash's Windows jq prints CRLF; on the Linux runner jq prints LF. Normalising
# here keeps a \r from ever leaking into a state key or a --argjson value, so the
# scripts behave identically on a maintainer's machine and in CI.
jqx() { jq "$@" 2> /dev/null | tr -d '\r'; }

# The one shape both files share: a per-channel object. Callers merge into it.
retry_default_state() { printf '{"stable":{},"beta":{}}'; }

# retry_load <file> — the file's JSON, or the empty per-channel default when it is
# absent, empty or unparseable. Never aborts the caller over a missing state file.
retry_load() {
	local f=${1:-} j
	if [ -n "$f" ] && [ -s "$f" ]; then
		j=$(jqx -c . "$f") || j=""
		if [ -n "$j" ] && [ "$j" != "null" ]; then
			printf '%s' "$j"
			return 0
		fi
	fi
	retry_default_state
}

# retry_channel_of_config <config-file> — "beta" or "stable", mirroring
# build_resolve_context.sh: the filename, or the pool's patches-version value.
retry_channel_of_config() {
	local cfg=${1:-} pv
	if [[ "$cfg" == *"beta"* ]]; then
		echo beta
		return 0
	fi
	if [[ "$cfg" == *.json ]] && [ -f "$cfg" ]; then
		pv=$(jqx -r '."patches-version" // empty' "$cfg") || pv=""
		[ "$pv" = "beta" ] && {
			echo beta
			return 0
		}
	fi
	echo stable
}

# retry_normalize_arch <token> — an `arch` value to its canonical, sorted,
# space-separated set of build-arch tokens. Empty/null/unknown falls back to the
# "both" default, matching what the build attempts when nothing is set.
retry_normalize_arch() {
	local tok=${1:-}
	tok="${tok,,}"
	case "$tok" in
	"" | both) printf 'arm-v7a arm64-v8a\n' ;;
	all | auto) printf 'all\n' ;;
	*) printf '%s\n' "$tok" ;;
	esac
}

# retry_effective_arch <config-file> <app-key> — the effective arch set for one
# app in a compiled config. The base compiler already merged file-level defaults
# into each entry, so a present `.arch` is authoritative; an absent one (null) is
# the "both" default. Output is the normalized set, one line.
retry_effective_arch() {
	local cfg=${1:-} key=${2:-} arch
	arch=$(jqx -r --arg k "$key" '.[$k].arch // empty' "$cfg") || arch=""
	retry_normalize_arch "$arch"
}

# The config keys whose value decides WHAT an artifact is built from, or WHETHER it
# is built at all. This is the one list — the watcher diffs it, the build job
# records it, and the trace suite asserts every key seen in a compiled config is
# either listed here or in the ignore list, so a new TOML key cannot silently join
# the class of "edits a maintainer thinks cost a build but that cost nothing".
#
# Deliberately NOT here:
#   * every `*-dlurl` — transport. The same version/versionCode/arch artifact is
#     fetched from whichever store answers; if a store ever serves different bytes,
#     the build's own content fingerprint says so on the next real build.
#   * `enabled` — membership, not a diff: the base compiler expresses `false` by
#     omitting the app, and the queue prune handles its return.
#   * `folder-name` — a typo no code reads (the real key is `patch-folder`).
retry_tracked_keys() {
	printf '%s\n' \
		patches-source patches-source-host patches-version patch-folder \
		cli-source cli-source-host cli-version \
		brand variant sub-variant app-name pkg-name patched-pkg-name \
		included-patches excluded-patches exclusive-patches inclusive-patches \
		patcher-args arch build-mode version version-code override-version-code \
		dpi include-stock compression-level compress-module-files \
		remove-rv-integrations-checks \
		mount-routing mount-secure-filesystem mount-app-storage mount-data-storage \
		fdroid-index github-release-regex github-regex \
		module-prop-name enable-module-update
}

# Keys a compiled config may carry that are DELIBERATELY not tracked, so the
# classification can be checked for completeness (trace case 19) instead of
# assumed. `*-dlurl` is matched by suffix, not by name, so a new store cannot slip in
# as an unclassified key.
#
#   *-dlurl                  transport; see the note on retry_tracked_keys.
#   enabled                  membership: the base compiler expresses `false` by
#                            omitting the app, and the queue prune handles the rest.
#   use-prebuilt-apks        local-dev input; no CI config carries it.
#   folder-name              a typo no code reads (the real key is `patch-folder`).
#   author, author-page      read from a config's FILE-LEVEL defaults only
#                            (build.sh takes them from `main_config_t`, never from an
#                            app block), so editing them in an app entry changes
#                            nothing. A file-level change is a repo-wide identity
#                            move, not a per-app build request.
retry_ignored_keys() {
	printf '%s\n' enabled use-prebuilt-apks folder-name author author-page
}

# retry_tracked_key <name> / retry_ignored_key <name> — is this key classified?
retry_tracked_key() {
	retry_tracked_keys | grep -qxF "$1"
}

retry_ignored_key() {
	local k=$1
	case "$k" in
	*-dlurl) return 0 ;;
	esac
	retry_ignored_keys | grep -qxF "$k"
}

# Keys an app may leave unset while the build still gives them a value. Only these
# two are filled in, because only these two have an unambiguous default in the
# engine itself (scripts/build.sh reads them with `|| DEF_*`). Every other absent
# key is recorded as "", so making a value explicit where it was absent is read as
# an edit — one extra rebuild, announced honestly — rather than depending on a
# hand-kept table of thirty defaults that would rot the moment a key changed.
retry_cfg_defaults() {
	jqx -cn '[$ARGS.positional[] | split("=") | {(.[0]): .[1]}] | add' \
		--args "arch=both" "build-mode=apk"
}

# retry_kinds_of <build-mode value> — the artifact kinds that spelling asks for,
# canonically ordered (apk before module, as the engine loops them). Empty or
# unknown falls back to "apk", matching scripts/build.sh's DEF_BUILD_MODE, so an
# inherited default and an explicit write of the same value cannot differ.
retry_kinds_of() {
	case "${1:-}" in
	both) printf 'apk module\n' ;;
	module) printf 'module\n' ;;
	*) printf 'apk\n' ;;
	esac
}

# retry_effective_kinds <config-file> <app-key> — the kinds one app asks for, read
# the same way the engine reads it.
retry_effective_kinds() {
	local cfg=${1:-} key=${2:-} bm
	bm=$(jqx -r --arg k "$key" '.[$k]["build-mode"] // empty' "$cfg") || bm=""
	retry_kinds_of "$bm"
}

# retry_shape_kinds <channel> <app-key> <built-shape-json> — the kinds the stored
# baseline asked for, normalized the same way retry_effective_kinds normalizes the
# config's, so the two sides of the widening test are comparable. Empty when there
# is no baseline to read them from.
retry_shape_kinds() {
	local c=${1:-} k=${2:-} src=${3:-} bm
	bm=$(retry_shape_cfg "$c" "$k" "$src")
	if [ "$bm" = '"NONE"' ]; then
		printf ''
		return 0
	fi
	bm=$(jqx -r '.["build-mode"] // ""' <<<"$bm")
	retry_kinds_of "$bm"
}

# retry_effective_cfg <config-file> <app-key> — the tracked fields of one app's
# compiled entry, as a compact JSON object with a fixed key order and every value
# stringified. Tracked keys the app leaves at their recorded value are dropped, so
# the map carries only what the maintainer actually wrote: keeping all of them would
# nearly sextuple this file for keys that are empty for every app in the pool. A
# value moving to or from empty is therefore a key appearing or disappearing, which
# the diff sees just as well.
# This is "the shape of the config the last successful build was produced from", in
# the only sense computable without guessing: what the maintainer asked for, minus
# the parts that cannot change the outcome.
# Not the same thing as a pending entry's `cfg`, which is the SHA-1 of the WHOLE
# entry (ADR 0010's re-arm signal) — narrower here on purpose, because transport
# and membership fields must not wake a finished app.
retry_effective_cfg() {
	local cfg=${1:-} key=${2:-} keys
	[ -n "$cfg" ] && [ -f "$cfg" ] || { printf '{}'; return 0; }
	keys=$(retry_tracked_keys | jqx -R . | jqx -sc .)
	jqx -c --arg k "$key" --argjson keys "$keys" --argjson defaults "$(retry_cfg_defaults)" '
		(.[$k] // {}) as $e
		| reduce $keys[] as $f ({};
			.[$f] = (
				if ($e | has($f)) then ($e[$f] | tostring)
				elif ($defaults | has($f)) then $defaults[$f]
				else "" end))
		| with_entries(select((.value != "") and (.value != null)))' "$cfg"
}

# retry_shape_arches <channel> <app-key> <built-shape-json> — the arch list of the
# stored entry, in either form: a legacy bare array, or {arches, cfg}. Unknown
# (absent) prints an empty array, which reads as "nothing built".
retry_shape_arches() {
	local c=${1:-} k=${2:-} src=${3:-}
	[ -n "$src" ] || src='{}'
	printf '%s' "$src" | jqx -c --arg c "$c" --arg k "$k" '
		(.[$c][$k] // [])
		| if type == "object" then (.arches // []) else . end'
}

# retry_shape_cfg <channel> <app-key> <built-shape-json> — the stored tracked map,
# or the word NONE when the entry carries no baseline (a legacy bare-array entry, or
# an app seeded before this field existed). A caller must treat NONE as "no
# evidence either way": record the current map and enqueue nothing, so deploying the
# comparison cannot force-rebuild the whole pool — the same cold-start guard the
# per-channel seed exists for.
retry_shape_cfg() {
	local c=${1:-} k=${2:-} src=${3:-}
	[ -n "$src" ] || src='{}'
	printf '%s' "$src" | jqx -c --arg c "$c" --arg k "$k" '
		(.[$c][$k] // null)
		| if (. == null) or (type != "object") or ((.cfg // null) == null) then "NONE"
		  else .cfg end'
}

# retry_arch_requested <failed-arch> <requested-set...> — success (0) when the
# failed arch is still among the requested arches, so it is worth retrying;
# failure (1) when the config no longer asks for it (e.g. "both" -> "arm64-v8a"
# drops an arm-v7a failure). Strict membership: an "all" request does not keep an
# "arm-v7a" retry alive, because no arm-v7a artifact is built any more.
retry_arch_requested() {
	local failed=${1:-}
	shift
	local a
	for a in "$@"; do
		[ "$a" = "$failed" ] && return 0
	done
	return 1
}

# retry_list_apps <config-file> — the app keys of a compiled config (objects only,
# so the top-level "patches-version" string is skipped).
retry_list_apps() {
	jqx -r 'to_entries | map(select(.value | type == "object")) | .[].key' "${1:-/dev/null}"
}

# retry_to_arr <space-separated tokens> -> sorted, unique JSON array. LC_ALL=C keeps
# the order byte-stable ("arm-v7a" before "arm64-v8a") regardless of runner locale.
retry_to_arr() {
	if [ -z "${1:-}" ]; then
		printf '[]'
	else
		# shellcheck disable=SC2086
		printf '%s\n' $1 | LC_ALL=C sort -u | jqx -R . | jqx -sc .
	fi
}

# retry_fingerprint <config-file> <app-key> — a stable hash of one app's own
# compiled entry: what the config says about that app, and nothing else. The
# watcher stores it on a pending entry (`cfg`) so the next run can tell "the
# maintainer changed this app's config" from "the same config failed again" —
# ADR 0010's re-arm. Keys are sorted first, because the base compiler emits the
# author's key order verbatim and merely reordering a TOML block is not a change
# worth spending a retry budget on.
retry_fingerprint() {
	local cfg=${1:-} key=${2:-} body
	body=$(jqx -c --arg k "$key" '(.[$k] // {}) | to_entries | sort_by(.key) | from_entries' "$cfg") || body=""
	printf '%s' "$body" | sha1sum | cut -d' ' -f1
}

# retry_app_base <app-label> <arch> — the config table name with the engine's
# " (<arch>)" build suffix removed, so per-arch failure records regroup under one
# key. Only the exact " (<arch>)" suffix is stripped.
retry_app_base() {
	local app=$1 arch=$2
	[ -n "$arch" ] && app="${app% ("$arch")}"
	printf '%s' "$app"
}
