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

# retry_app_base <app-label> <arch> — the config table name with the engine's
# " (<arch>)" build suffix removed, so per-arch failure records regroup under one
# key. Only the exact " (<arch>)" suffix is stripped.
retry_app_base() {
	local app=$1 arch=$2
	[ -n "$arch" ] && app="${app% ("$arch")}"
	printf '%s' "$app"
}
