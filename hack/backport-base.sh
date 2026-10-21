#!/usr/bin/env bash
#
# Bring the UBI9 base and the staleness gate to a release branch.
#
# The release branches publish :4.18 .. :4.23, and they were all still
# building on quay.io/openshift/origin-must-gather:latest. Fixing only main
# would have left every version-tagged image on a base last rebuilt in
# February, which is the thing that prompted this work.
#
# A release branch pins oc to its own minor rather than tracking stable, so
# the 4.18 image ships an oc 4.18 client. That is the whole point of having
# the branch.
#
#   hack/backport-base.sh release-4.18 release-4.19 ...
#   hack/backport-base.sh --all
#
# Run from a clean tree on main. Each branch is reset and cleaned first:
# leftovers from the previous branch leaking into the next one is a mistake
# this repo has already made once.

set -eu -o pipefail

cd "$(git rev-parse --show-toplevel)"

SOURCE_REF=main

branches=()
if [[ "${1:-}" == "--all" ]]; then
	mapfile -t branches < <(git for-each-ref --format='%(refname:short)' 'refs/heads/release-*' | sort -V)
else
	branches=("$@")
fi

if [[ ${#branches[@]} -eq 0 ]]; then
	echo "usage: ${BASH_SOURCE[0]##*/} [--all | release-4.18 ...]" >&2
	exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
	echo "working tree is dirty; commit or stash first" >&2
	exit 1
fi

start_branch="$(git rev-parse --abbrev-ref HEAD)"
staging="$(mktemp -d)"
trap 'rm -rf "${staging}"' EXIT

# Take the files to port from the source ref rather than the worktree, so the
# script does not depend on which branch happens to be checked out.
for f in Dockerfile.base Dockerfile.overlay hack/check-base.sh tests/check_base.bats; do
	mkdir -p "${staging}/$(dirname "$f")"
	git show "${SOURCE_REF}:$f" >"${staging}/$f"
done

for branch in "${branches[@]}"; do
	version="${branch#release-}"
	echo "=== ${branch} (oc pinned to stable-${version})"

	git checkout -q "${branch}"
	git reset -q --hard "origin/${branch}"
	git clean -qfd

	cp "${staging}/hack/check-base.sh" hack/check-base.sh
	chmod +x hack/check-base.sh
	cp "${staging}/tests/check_base.bats" tests/check_base.bats
	cp "${staging}/Dockerfile.overlay" Dockerfile.overlay

	# stable-4.18 and friends are real paths on mirror.openshift.com; a bare
	# "4.18" is a 404.
	sed "s/^ARG OC_VERSION=stable$/ARG OC_VERSION=stable-${version}/" \
		"${staging}/Dockerfile.base" >Dockerfile.base
	grep -q "^ARG OC_VERSION=stable-${version}$" Dockerfile.base

	python3 hack/backport_base_edits.py "${version}"

	git add -A Dockerfile.base Dockerfile.overlay hack/check-base.sh \
		tests/check_base.bats Makefile .github/workflows/ci.yml
	git commit -q -F - <<-EOF
		Stop building ${version} on a stale base; build a current one from UBI9

		This image adds only shell scripts, so every CVE a scan reports
		against it comes from its base -- and :${version} was still being
		published on quay.io/openshift/origin-must-gather:latest, last
		rebuilt in February. All of that staleness showed up as though it
		were ours.

		There is no fresher public must-gather image to use instead;
		latest is the newest tag it publishes. Dockerfile.base builds one
		from registry.access.redhat.com/ubi9/ubi-minimal, which Red Hat
		rebuilds continuously and which needs no pull credentials.

		oc is pinned to stable-${version} rather than tracking stable, so
		the ${version} image ships a ${version} client to match the
		collection scripts on this branch.

		Dockerfile.overlay's BASE loses its default, so a build that does
		not say what it is layering onto fails instead of quietly picking
		something months old, and hack/check-base.sh fails past 60 days
		with CI running it before publishing.

		Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
	EOF

	echo "    committed $(git rev-parse --short HEAD)"
done

git checkout -q "${start_branch}"
echo
echo "done. Review with: git log --oneline ${branches[0]} -1"
echo "Push with:        git push origin ${branches[*]}"
