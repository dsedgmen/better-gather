#!/usr/bin/env bash
#
# Bring the disclaimer and the security scans to a release branch.
#
# These branches publish :4.18 .. :4.23 under the same names as main, so the
# same statement has to travel with them: not a Red Hat product, unsupported,
# no warranty. It goes in the README, in the image labels, in a DISCLAIMER
# file in the image, and into every collection gather produces.
#
# Idempotent: each edit checks whether it has already been applied, so a
# branch can be re-run without doubling up.
#
#   hack/backport-disclaimer.sh release-4.18 release-4.19 ...
#   hack/backport-disclaimer.sh --all
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
# backport_disclaimer_edits.py is staged too: the release branch does not have it,
# so it has to be run from here rather than from the checked-out tree.
for f in DISCLAIMER .trivyignore Dockerfile.overlay tests/disclaimer.bats \
	hack/tools-from-packages.sh hack/backport_disclaimer_edits.py; do
	mkdir -p "${staging}/$(dirname "$f")"
	git show "${SOURCE_REF}:$f" >"${staging}/$f"
done

for branch in "${branches[@]}"; do
	version="${branch#release-}"
	echo "=== ${branch}"

	git checkout -q "${branch}"
	git reset -q --hard "origin/${branch}"
	git clean -qfd

	cp "${staging}/DISCLAIMER" DISCLAIMER
	cp "${staging}/.trivyignore" .trivyignore
	cp "${staging}/tests/disclaimer.bats" tests/disclaimer.bats
	cp "${staging}/Dockerfile.overlay" Dockerfile.overlay
	cp "${staging}/hack/tools-from-packages.sh" hack/tools-from-packages.sh
	chmod +x hack/tools-from-packages.sh

	python3 "${staging}/hack/backport_disclaimer_edits.py" "${version}"

	git add -A DISCLAIMER .trivyignore Dockerfile.overlay tests/disclaimer.bats \
		hack/tools-from-packages.sh collection-scripts/gather README.md \
		Makefile .github/workflows/ci.yml
	git commit -q -F - <<-EOF
		Say plainly that ${version} is not a Red Hat product, and scan it

		This branch publishes :${version} under the same name as main, so
		the same statement has to travel with it. The disclaimer goes in
		the README, in the image labels, in /usr/share/better-gather/
		DISCLAIMER, and -- the one that matters -- gather prints it at
		startup and copies it into the collection. Whoever reads a
		must-gather tarball is rarely whoever ran it, and nothing else in
		the archive would say it did not come from the supported image.

		Security scanning is reporting only: CI runs trivy over the tree
		and over the built image before publishing, printing a table and
		keeping JSON as an artifact, and neither fails the build. The
		staleness gate is what actually keeps the base current.

		Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
	EOF

	echo "    committed $(git rev-parse --short HEAD)"
done

git checkout -q "${start_branch}"
echo
echo "done. Review with: git log --oneline ${branches[0]} -1"
echo "Push with:        git push origin ${branches[*]}"
