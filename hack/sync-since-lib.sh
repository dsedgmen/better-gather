#!/usr/bin/env bash
#
# Copy the canonical since_common.sh into the sibling must-gather forks.
#
# The CNV and ODF must-gather images are built from their own repositories, so
# each needs its own copy of the library rather than a build-time dependency —
# that is simply how must-gather images ship, with collection-scripts/ copied
# straight into /usr/bin.
#
# This repo holds the canonical copy. Each fork carries a test asserting its
# vendored copy is byte-identical, so drift fails the suite instead of rotting
# quietly.
#
#   hack/sync-since-lib.sh ../better-gather-cnv ../better-gather-odf
#   hack/sync-since-lib.sh --check ../better-gather-cnv      # verify only
#
# Exits non-zero under --check if any copy differs, so CI can use it.

set -eu -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r PROJECT_ROOT
declare -r LIB="collection-scripts/since_common.sh"
declare -r SOURCE="${PROJECT_ROOT}/${LIB}"

check_only=false
if [[ "${1:-}" == "--check" ]]; then
	check_only=true
	shift
fi

if [[ $# -eq 0 ]]; then
	echo "usage: ${BASH_SOURCE[0]##*/} [--check] <fork-dir>..." >&2
	exit 2
fi

if [[ ! -f "$SOURCE" ]]; then
	echo "ERROR: canonical library missing: $SOURCE" >&2
	exit 1
fi

status=0
for fork in "$@"; do
	target="${fork%/}/${LIB}"

	if [[ ! -d "${fork%/}/collection-scripts" ]]; then
		echo "ERROR: ${fork} does not look like a must-gather fork" >&2
		status=1
		continue
	fi

	if [[ "$check_only" == true ]]; then
		if [[ ! -f "$target" ]]; then
			echo "MISSING  $target"
			status=1
		elif cmp -s "$SOURCE" "$target"; then
			echo "OK       $target"
		else
			echo "DRIFTED  $target"
			diff -u "$SOURCE" "$target" || true
			status=1
		fi
		continue
	fi

	if [[ -f "$target" ]] && cmp -s "$SOURCE" "$target"; then
		echo "UNCHANGED $target"
	else
		cp "$SOURCE" "$target"
		echo "SYNCED    $target"
	fi
done

exit "$status"
