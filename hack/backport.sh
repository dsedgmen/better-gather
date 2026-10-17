#!/usr/bin/env bash
#
# Create (or refresh) a release-X.Y backport branch from the matching
# upstream branch.
#
# These are real backports, not cherry-picks: release-4.18 is 93 commits and
# 41 collection scripts behind main, so replaying our commits would drag
# unrelated upstream changes with them. Instead the branch starts from
# upstream's own release branch and the --since work is re-applied onto it:
#
#   * files that are entirely ours are taken from main verbatim -- the
#     library, the tests, the hack scripts, the Dockerfile, the workflow;
#   * upstream's own collection scripts are edited in place, matching the
#     text as it exists on *that* branch.
#
# Every edit reports whether it matched, so a branch where upstream has moved
# the ground under us fails loudly instead of silently producing a branch
# that looks fine and collects everything.
#
#   hack/backport.sh 4.18
#   hack/backport.sh 4.18 4.19 4.20 4.21 4.22 4.23
#
# Verify afterwards with: make GO_REQUIRED_MIN_VERSION:= bats-check

set -eu -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r PROJECT_ROOT
cd "$PROJECT_ROOT"

SOURCE_BRANCH="${SOURCE_BRANCH:-main}"

# Files that exist only because of this fork. Safe to take wholesale: there
# is no upstream version to conflict with.
OURS=(
	collection-scripts/since_common.sh
	hack/tools-from-packages.sh
	hack/sync-since-lib.sh
	hack/try-on-cluster.sh
	hack/backport.sh
	tests/bats_assert_fallback.bash
	tests/since_common.bats
	tests/test_helper.bash
	Dockerfile.overlay
	.github/workflows/ci.yml
)

backport_one() {
	local version="$1"
	local branch="release-${version}"
	local upstream="upstream/${branch}"

	echo "=============================================================="
	echo "  ${branch}"
	echo "=============================================================="

	if ! git rev-parse --verify --quiet "${upstream}" >/dev/null; then
		echo "SKIP: ${upstream} does not exist" >&2
		return 1
	fi

	git checkout -q -B "${branch}" "${upstream}"

	local f
	for f in "${OURS[@]}"; do
		mkdir -p "$(dirname "$f")"
		git checkout -q "${SOURCE_BRANCH}" -- "$f" 2>/dev/null ||
			echo "  note: ${SOURCE_BRANCH} has no ${f}"
	done

	# Older release branches predate the bats suite entirely; they get the
	# whole tests/ directory and the Makefile targets from us.
	if [ ! -f tests/common.bats ]; then
		git checkout -q "${SOURCE_BRANCH}" -- tests/ 2>/dev/null || true
		echo "  note: branch had no tests/, took the suite from ${SOURCE_BRANCH}"
	fi

	python3 hack/backport_edits.py || return 1

	git add -A
	if git diff --cached --quiet; then
		echo "  nothing to do"
		return 0
	fi
	git commit -q -F - <<EOF
Backport the --since work to ${version}

Re-applied onto upstream/${branch} rather than cherry-picked: that branch is
far enough behind main that replaying the commits would carry unrelated
upstream changes with them.

See the README for what this changes and why. The same bats suite runs here,
and CI builds and publishes ghcr.io/dsedgmen/<image>:${version}.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
	echo "  committed $(git rev-parse --short=8 HEAD)"
}

main() {
	local original
	original="$(git rev-parse --abbrev-ref HEAD)"
	trap 'git checkout -q "${original}" 2>/dev/null || true' EXIT

	if [ "$#" -eq 0 ]; then
		echo "usage: ${BASH_SOURCE[0]##*/} <version>..." >&2
		exit 2
	fi

	local v failed=0
	for v in "$@"; do
		backport_one "$v" || failed=$((failed + 1))
	done

	[ "$failed" -eq 0 ] || {
		echo "${failed} branch(es) failed" >&2
		exit 1
	}
}

main "$@"
