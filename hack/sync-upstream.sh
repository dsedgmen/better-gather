#!/usr/bin/env bash
#
# Keep this fork current with its upstream must-gather.
#
#   hack/sync-upstream.sh           # fetch, open sync PRs, publish new releases
#   hack/sync-upstream.sh --dry-run # print what would happen
#
# For main: merge upstream/main onto a sync/upstream-main branch and open a PR.
# For each existing origin/release-X.Y that lags upstream: re-apply the full
# backport chain and open a PR into that release branch.
# For each new upstream/release-X.Y at or above the floor (oldest existing
# origin/release-*, or 4.18): full backport and push origin/release-X.Y, then
# open a tracking Issue. Never pushes bare upstream.
#
# Env overrides: UPSTREAM_URL, IMAGE_NAME, ENABLE_RELEASE_SYNC (1/0),
# RELEASE_FLOOR, DRY_RUN=1

set -eu -o pipefail

cd "$(git rev-parse --show-toplevel)"

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/openshift/must-gather.git}"
IMAGE_NAME="${IMAGE_NAME:-better-gather}"
ENABLE_RELEASE_SYNC="${ENABLE_RELEASE_SYNC:-1}"
RELEASE_FLOOR="${RELEASE_FLOOR:-}"
LABEL="upstream-sync"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]] || [[ "${DRY_RUN:-0}" == "1" ]]; then
	DRY_RUN=1
fi

start_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
start_sha="$(git rev-parse HEAD)"
restore_tree() {
	git checkout -q "${start_branch}" 2>/dev/null ||
		git checkout -q -B "${start_branch}" "${start_sha}" 2>/dev/null ||
		true
}
trap restore_tree EXIT

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

version_ge() {
	# True if $1 >= $2 under sort -V.
	[[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
}

ensure_upstream_remote() {
	if git remote get-url upstream >/dev/null 2>&1; then
		git remote set-url upstream "${UPSTREAM_URL}"
	else
		git remote add upstream "${UPSTREAM_URL}"
	fi
}

ensure_label() {
	[[ "${DRY_RUN}" -eq 1 ]] && return 0
	gh label create "${LABEL}" --description "Automated upstream must-gather sync" \
		--color "0E8A16" 2>/dev/null || true
}

open_or_update_pr() {
	local base="$1" head="$2" title="$3" body="$4"
	if [[ "${DRY_RUN}" -eq 1 ]]; then
		log "DRY-RUN: would open/update PR ${head} -> ${base}: ${title}"
		return 0
	fi
	local existing
	existing="$(gh pr list --state open --base "${base}" --head "${head}" \
		--json number --jq '.[0].number // empty')"
	if [[ -n "${existing}" ]]; then
		gh pr edit "${existing}" --title "${title}" --body "${body}" >/dev/null
		gh pr edit "${existing}" --add-label "${LABEL}" >/dev/null 2>&1 || true
		log "Updated PR #${existing}: ${head} -> ${base}"
	else
		local url
		url="$(gh pr create --base "${base}" --head "${head}" \
			--title "${title}" --body "${body}")"
		gh pr edit "${url}" --add-label "${LABEL}" >/dev/null 2>&1 || true
		log "Opened PR: ${url}"
	fi
}

open_issue() {
	local title="$1" body="$2"
	if [[ "${DRY_RUN}" -eq 1 ]]; then
		log "DRY-RUN: would open issue: ${title}"
		return 0
	fi
	# Avoid duplicates for the same title while open.
	local existing
	existing="$(gh issue list --state open --label "${LABEL}" --search "in:title ${title}" \
		--json number,title --jq ".[] | select(.title == \"${title}\") | .number" | head -1)"
	if [[ -n "${existing}" ]]; then
		gh issue comment "${existing}" --body "${body}" >/dev/null
		log "Commented on issue #${existing}: ${title}"
	else
		local url
		url="$(gh issue create --title "${title}" --body "${body}")"
		gh issue edit "${url}" --add-label "${LABEL}" >/dev/null 2>&1 || true
		log "Opened issue: ${url}"
	fi
}

push_branch() {
	local local_ref="$1" remote_ref="$2" force="${3:-0}"
	if [[ "${DRY_RUN}" -eq 1 ]]; then
		log "DRY-RUN: would push ${local_ref} -> origin/${remote_ref} (force=${force})"
		return 0
	fi
	if [[ "${force}" -eq 1 ]]; then
		git push -u origin "+${local_ref}:refs/heads/${remote_ref}"
	else
		git push -u origin "${local_ref}:refs/heads/${remote_ref}"
	fi
}

refresh_release() {
	local version="$1"
	local branch="release-${version}"
	log "Refreshing ${branch} from upstream/${branch}"
	./hack/backport.sh "${version}"
	./hack/backport-base.sh --onto-head "${branch}"
	./hack/backport-disclaimer.sh --onto-head "${branch}"
}

sync_main() {
	if git merge-base --is-ancestor upstream/main origin/main 2>/dev/null; then
		log "main: already contains upstream/main"
		return 0
	fi
	local up_sha
	up_sha="$(git rev-parse --short upstream/main)"
	log "main: merging upstream/main (${up_sha})"
	git checkout -q -B sync/upstream-main origin/main
	if [[ "${DRY_RUN}" -eq 1 ]]; then
		log "DRY-RUN: would merge upstream/main into sync/upstream-main and open PR"
		git checkout -q "${start_branch}"
		return 0
	fi
	if ! git merge --no-edit upstream/main; then
		git merge --abort 2>/dev/null || true
		open_issue "upstream sync: main merge conflicts" \
			"\`hack/sync-upstream.sh\` could not merge \`upstream/main\` (${up_sha}) into \`main\`.

Resolve locally with \`git fetch upstream && git checkout main && git merge upstream/main\`, then push."
		die "merge conflicts bringing upstream/main into main"
	fi
	push_branch sync/upstream-main sync/upstream-main 1
	open_or_update_pr main sync/upstream-main \
		"Sync upstream/main (${up_sha})" \
		"Automated merge of \`upstream/main\` (${up_sha}) into \`main\`.

CI should pass before merge. Source: ${UPSTREAM_URL}"
}

list_origin_release_versions() {
	git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/release-*' |
		sed 's#^origin/release-##' | sort -V
}

list_upstream_release_versions() {
	git for-each-ref --format='%(refname:short)' 'refs/remotes/upstream/release-*' |
		sed 's#^upstream/release-##' | sort -V
}

release_floor() {
	if [[ -n "${RELEASE_FLOOR}" ]]; then
		printf '%s\n' "${RELEASE_FLOOR}"
		return 0
	fi
	local oldest
	oldest="$(list_origin_release_versions | head -1 || true)"
	if [[ -n "${oldest}" ]]; then
		printf '%s\n' "${oldest}"
	else
		printf '%s\n' "4.18"
	fi
}

sync_existing_releases() {
	local version branch up_sha
	while IFS= read -r version; do
		[[ -n "${version}" ]] || continue
		branch="release-${version}"
		if ! git rev-parse --verify --quiet "upstream/${branch}" >/dev/null; then
			log "${branch}: no matching upstream branch; skip"
			continue
		fi
		if git merge-base --is-ancestor "upstream/${branch}" "origin/${branch}" 2>/dev/null; then
			log "${branch}: already contains upstream/${branch}"
			continue
		fi
		up_sha="$(git rev-parse --short "upstream/${branch}")"
		log "${branch}: upstream moved (${up_sha}); refreshing"
		if [[ "${DRY_RUN}" -eq 1 ]]; then
			log "DRY-RUN: would refresh ${branch} and open PR"
			continue
		fi
		if ! refresh_release "${version}"; then
			open_issue "upstream sync failed: ${branch}" \
				"Re-applying the fork onto \`upstream/${branch}\` (${up_sha}) failed.

Likely \`hack/backport_edits.py\` found no match. Fix the edit script against the new upstream text and re-run \`hack/sync-upstream.sh\`."
			die "refresh failed for ${branch}"
		fi
		git branch -f "sync/upstream-${branch}" "${branch}"
		push_branch "sync/upstream-${branch}" "sync/upstream-${branch}" 1
		open_or_update_pr "${branch}" "sync/upstream-${branch}" \
			"Sync upstream/${branch} (${up_sha})" \
			"Automated refresh of \`${branch}\` from \`upstream/${branch}\` (${up_sha}).

Full re-apply of --since, UBI9 base, and disclaimer (not a cherry-pick). CI should pass before merge."
	done < <(list_origin_release_versions)
}

publish_new_releases() {
	local floor version branch up_sha
	floor="$(release_floor)"
	log "release floor: ${floor}"
	while IFS= read -r version; do
		[[ -n "${version}" ]] || continue
		version_ge "${version}" "${floor}" || continue
		branch="release-${version}"
		if git rev-parse --verify --quiet "origin/${branch}" >/dev/null; then
			continue
		fi
		up_sha="$(git rev-parse --short "upstream/${branch}")"
		log "${branch}: new upstream branch (${up_sha}); publishing"
		if [[ "${DRY_RUN}" -eq 1 ]]; then
			log "DRY-RUN: would backport and push origin/${branch}"
			continue
		fi
		if ! refresh_release "${version}"; then
			open_issue "upstream sync: failed to publish ${branch}" \
				"Upstream has \`${branch}\` (${up_sha}) but the full backport failed, so it was not pushed.

Fix \`hack/backport_edits.py\` (or base/disclaimer helpers) for this line and re-run \`hack/sync-upstream.sh\`."
			die "publish failed for ${branch}"
		fi
		push_branch "${branch}" "${branch}" 0
		open_issue "Published new ${branch} from upstream" \
			"Created \`${branch}\` from \`upstream/${branch}\` (${up_sha}) with the full fork backport applied (--since, UBI9 base, disclaimer).

CI on push should build and publish \`ghcr.io/dsedgmen/${IMAGE_NAME}:${version}\`."
	done < <(list_upstream_release_versions)
}

main() {
	command -v gh >/dev/null || die "gh is required"
	command -v python3 >/dev/null || die "python3 is required"

	if [[ -n "$(git status --porcelain)" ]]; then
		if [[ "${DRY_RUN}" -eq 1 ]]; then
			log "note: working tree is dirty; continuing because --dry-run"
		else
			die "working tree is dirty; commit or stash first"
		fi
	fi

	ensure_upstream_remote
	log "Fetching origin and upstream..."
	git fetch origin --prune
	git fetch upstream --prune

	ensure_label
	sync_main

	if [[ "${ENABLE_RELEASE_SYNC}" == "1" ]]; then
		sync_existing_releases
		publish_new_releases
	else
		log "release sync disabled"
	fi

	log "done"
}

main "$@"
