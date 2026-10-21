#!/usr/bin/env bash
#
# Report how old a base image is, and fail if it is older than we are willing
# to ship on.
#
# This image adds only shell scripts, so every vulnerability it reports comes
# from its base. Layering onto a stale community image is how a scan ends up
# far worse than a stock must-gather, and nothing about the build would
# otherwise tell you that had happened.
#
#   hack/check-base.sh quay.io/openshift/origin-must-gather:latest
#   hack/check-base.sh --max-age 30 "$(oc adm release info --image-for=must-gather)"
#   hack/check-base.sh --warn-only <image>     # report, never fail
#
# Needs skopeo; falls back to podman if it is not installed.

set -eu -o pipefail

MAX_AGE_DAYS="${MAX_AGE_DAYS:-60}"
warn_only=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--max-age)
		MAX_AGE_DAYS="$2"
		shift 2
		;;
	--warn-only)
		warn_only=true
		shift
		;;
	-h | --help)
		sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) break ;;
	esac
done

image="${1:-}"
if [[ -z "$image" ]]; then
	echo "usage: ${BASH_SOURCE[0]##*/} [--max-age DAYS] [--warn-only] <image>" >&2
	exit 2
fi

created=""
if command -v skopeo >/dev/null 2>&1; then
	created="$(skopeo inspect "docker://${image}" 2>/dev/null |
		sed -n 's/.*"Created": *"\([0-9-]\{10\}\).*/\1/p' | head -1)"
elif command -v podman >/dev/null 2>&1; then
	podman pull -q "${image}" >/dev/null 2>&1 || true
	created="$(podman image inspect "${image}" --format '{{.Created}}' 2>/dev/null | cut -c1-10)"
fi

if [[ -z "$created" ]]; then
	echo "WARNING: could not determine when ${image} was built" >&2
	echo "         (private registry? no credentials?) -- not failing on that alone" >&2
	exit 0
fi

age=$((($(date +%s) - $(date -d "${created}" +%s)) / 86400))

printf '%s\n' "base:  ${image}"
printf '%s\n' "built: ${created} (${age} days ago)"

if [[ "$age" -le "$MAX_AGE_DAYS" ]]; then
	echo "ok:    within the ${MAX_AGE_DAYS} day limit"
	exit 0
fi

echo
echo "This base is ${age} days old, past the ${MAX_AGE_DAYS} day limit. Anything"
echo "built on it inherits every CVE fixed upstream since then, and this image"
echo "adds no packages of its own, so that is the whole of its exposure."
echo
echo "Prefer the image your cluster already runs -- it carries exactly the CVEs"
echo "you have already accepted:"
echo
echo "    make image-overlay BASE=\$(oc adm release info --image-for=must-gather)"

if [[ "$warn_only" == true ]]; then
	echo
	echo "(--warn-only: continuing anyway)"
	exit 0
fi
exit 1
