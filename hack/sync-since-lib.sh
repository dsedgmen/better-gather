#!/usr/bin/env bash
#
# Copy the canonical shared libraries into the sibling must-gather forks.
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
# The tests travel with the library they cover. They source since_common.sh
# directly rather than reaching it through a common.sh, so one file works in
# every fork and can be compared byte for byte.
declare -ra LIBS=(
	collection-scripts/since_common.sh
	tests/since_common.bats
)

check_only=false
if [[ "${1:-}" == "--check" ]]; then
	check_only=true
	shift
fi

if [[ $# -eq 0 ]]; then
	echo "usage: ${BASH_SOURCE[0]##*/} [--check] <fork-dir>..." >&2
	exit 2
fi

status=0
for fork in "$@"; do
	if [[ ! -d "${fork%/}/collection-scripts" ]]; then
		echo "ERROR: ${fork} does not look like a must-gather fork" >&2
		status=1
		continue
	fi

	for lib in "${LIBS[@]}"; do
		source_file="${PROJECT_ROOT}/${lib}"
		target="${fork%/}/${lib}"

		if [[ ! -f "$source_file" ]]; then
			echo "ERROR: canonical library missing: $source_file" >&2
			status=1
			continue
		fi

		if [[ "$check_only" == true ]]; then
			if [[ ! -f "$target" ]]; then
				echo "MISSING  $target"
				status=1
			elif cmp -s "$source_file" "$target"; then
				echo "OK       $target"
			else
				echo "DRIFTED  $target"
				diff -u "$source_file" "$target" || true
				status=1
			fi
			continue
		fi

		if [[ -f "$target" ]] && cmp -s "$source_file" "$target"; then
			echo "UNCHANGED $target"
		else
			cp "$source_file" "$target"
			echo "SYNCED    $target"
		fi
	done
done

exit "$status"
