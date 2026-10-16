#!/bin/bash
#
# Applying the collection window ourselves.
#
# `oc adm must-gather --since` reaches collection in only two ways: as --since
# on `oc adm inspect`, and as --since on an `oc adm node-logs` *journal* query.
# It reaches nothing else, because oc attaches the since parameter only when
# the node-logs path is 'journal' (openshift/oc, pkg/cli/admin/node/logs.go),
# and the kubelet does not time-filter plain file serving even when handed the
# parameter directly. Measured on 4.18: a rotated audit file comes back whole,
# all 134269 lines, for --since=-5m, --since=-1h and --since='<timestamp>'.
#
# So the scripts that collect files have to apply the window themselves. There
# are two shapes of that, and a helper for each:
#
#   name-based   the collection produces a listing whose entries carry a
#                timestamp (audit-2026-10-16T00-15-40.612.log,
#                insights-2026-10-16-181710.tar.gz)  ->  filter_names_since
#
#   mtime-based  the collection tars or copies a whole directory and has no
#                notion of time at all  ->  since_find_predicate,
#                copy_pod_dir_since
#
# Everything here is a no-op when no window was requested, so sourcing it
# cannot change the default behaviour of a script.
#
# This file is deliberately self-contained: it is vendored verbatim into the
# CNV and ODF must-gather forks, which have no common.sh. Keep it that way --
# hack/sync-since-lib.sh copies it, and each fork tests that its copy matches.

# Convert a Go duration (as oc writes MUST_GATHER_SINCE: 30m0s, 2h30m0s) into
# total whole seconds. Sub-second components are dropped; they cannot move a
# whole-second cutoff. Echoes 0 when nothing parses.
duration_to_seconds() {
	local rest="${1:-}" total=0 value unit

	# Remove sub-second components first so that, for example, the 'm' of
	# '500ms' is never mistaken for minutes.
	rest="$(echo "${rest}" | sed -E 's/[0-9]+(\.[0-9]+)?(ns|us|µs|ms)//g')"
	# Truncate fractions on the remaining units: 1.5s counts as 1 second.
	rest="$(echo "${rest}" | sed -E 's/([0-9]+)\.[0-9]+/\1/g')"

	while [[ "${rest}" =~ ^([0-9]+)([dhms])(.*)$ ]]; do
		value="${BASH_REMATCH[1]}"
		unit="${BASH_REMATCH[2]}"
		rest="${BASH_REMATCH[3]}"
		case "${unit}" in
		d) total=$((total + value * 86400)) ;;
		h) total=$((total + value * 3600)) ;;
		m) total=$((total + value * 60)) ;;
		s) total=$((total + value)) ;;
		esac
	done

	echo "${total}"
}

# Collapse a Go duration into the single component that `oc adm node-logs
# --since` accepts: '(+|-)[0-9]+(s|m|h|d)'.
#
# The result is always exactly equal to the input, never rounded. The unit is
# only cosmetic -- pick the largest one that divides the total evenly, and fall
# back to seconds, which is always exact. So 2h30m0s becomes 150m, not 2h
# (which loses half an hour) and not 3h (which collects more than was asked
# for).
duration_to_node_logs_since() {
	local seconds
	seconds="$(duration_to_seconds "${1:-}")"

	if [ "${seconds}" -le 0 ]; then
		if [[ "${1:-}" =~ [0-9](ns|us|µs|ms) ]]; then
			# A sub-second window. node-logs has no finer unit than the
			# second, so ask for one. Passing the original through would
			# hand it '500ms', which it reads as 500 *minutes*.
			echo "1s"
		else
			# Nothing recognisable; pass the original through untouched so
			# the behaviour is no worse than not having this function.
			echo "${1:-}"
		fi
	elif [ "$((seconds % 86400))" -eq 0 ]; then
		echo "$((seconds / 86400))d"
	elif [ "$((seconds % 3600))" -eq 0 ]; then
		echo "$((seconds / 3600))h"
	elif [ "$((seconds % 60))" -eq 0 ]; then
		echo "$((seconds / 60))m"
	else
		echo "${seconds}s"
	fi
}

# Resolve the requested collection window to an absolute cutoff, for the
# collection that has to apply the window itself. See since_common.sh.
#
# Sets:
#   since_cutoff_epoch   - seconds since the epoch, empty when no window was
#                          requested
#   since_cutoff_rfc3339 - the same instant, RFC3339 UTC
#
# MUST_GATHER_SINCE_TIME wins over MUST_GATHER_SINCE, matching the precedence
# get_log_collection_args already uses.
get_since_cutoff() {
	local seconds
	since_cutoff_epoch=""
	since_cutoff_rfc3339=""

	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		since_cutoff_epoch="$(date -u -d "${MUST_GATHER_SINCE_TIME}" +%s 2>/dev/null)" ||
			since_cutoff_epoch=""
	elif [ -n "${MUST_GATHER_SINCE:-}" ]; then
		seconds="$(duration_to_seconds "${MUST_GATHER_SINCE}")"
		if [ "${seconds}" -gt 0 ]; then
			since_cutoff_epoch="$(($(date -u +%s) - seconds))"
		fi
	fi

	if [ -n "${since_cutoff_epoch}" ]; then
		since_cutoff_rfc3339="$(date -u -d "@${since_cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
	fi

	export since_cutoff_epoch since_cutoff_rfc3339
}

SINCE_REPORT_PATH="${SINCE_REPORT_PATH:-${BASE_COLLECTION_PATH:-/must-gather}/since-report.txt}"

# Make sure the cutoff is available to every helper below. Scripts may also
# call get_since_cutoff themselves; it is idempotent.
since_cutoff_epoch="${since_cutoff_epoch:-}"
since_cutoff_rfc3339="${since_cutoff_rfc3339:-}"

# True when a collection window was requested.
since_window_requested() {
	[ -n "${since_cutoff_epoch:-}" ]
}

# The find(1) predicate that limits results to the window, or nothing at all.
# Intended for unquoted expansion, exactly like log_collection_args:
#
#   find /var/log/ovnkube -type f $(since_find_predicate) -name 'libovsdb*log*'
#
since_find_predicate() {
	if since_window_requested; then
		echo "-newermt @${since_cutoff_epoch}"
	fi
}

# Echo the epoch seconds encoded in a log file name, or nothing when the name
# carries no recognisable timestamp.
#
# Understood, because these are what OpenShift actually produces:
#   audit-2026-10-16T00-15-40.612.log      rotated apiserver logs
#   insights-2026-10-16-181710.tar.gz      insights archives
#   something-2026-10-16T00:15:40Z.log     RFC3339 in a name
filename_timestamp_epoch() {
	local name="$1" stamp=""

	# 2026-10-16T00-15-40 (audit style: 'T' separator, '-' in the time)
	stamp="$(echo "${name}" |
		sed -nE 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})[-:]([0-9]{2})[-:]([0-9]{2}).*/\1 \2:\3:\4/p')"

	# 2026-10-16-181710 (insights style: '-' separator, no punctuation in time)
	if [ -z "${stamp}" ]; then
		stamp="$(echo "${name}" |
			sed -nE 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}).*/\1 \2:\3:\4/p')"
	fi

	if [ -z "${stamp}" ]; then
		return 0
	fi

	date -u -d "${stamp} UTC" +%s 2>/dev/null || true
}

# Filter a listing on stdin, dropping entries whose embedded timestamp predates
# the cutoff.
#
# Entries with no recognisable timestamp are always kept. That is deliberate
# and load-bearing: it keeps the live audit.log, termination.log, .lock and
# .terminating, which have no timestamp in the name but are exactly the files
# most likely to contain recent events.
#
# A rotated file named for time T holds events up to T, so it is in scope when
# T >= cutoff.
#
# Usage: ... | filter_names_since [label]
filter_names_since() {
	local label="${1:-collection}"
	local line name epoch kept=0 skipped=0

	if ! since_window_requested; then
		cat
		return 0
	fi

	while IFS= read -r line; do
		# Listings from --role=<role> are prefixed with the node name.
		name="${line##* }"
		epoch="$(filename_timestamp_epoch "${name}")"

		if [ -z "${epoch}" ] || [ "${epoch}" -ge "${since_cutoff_epoch}" ]; then
			printf '%s\n' "${line}"
			kept=$((kept + 1))
		else
			skipped=$((skipped + 1))
		fi
	done

	since_report "${label}" "filename-timestamp" "${kept}" "${skipped}"
}

# Copy a directory out of a pod, limited to files modified inside the window.
#
# Replaces `oc cp <ns>/<pod>:<src> <dest>`, which has no way to express a time
# bound. Streams a tarball built from a find(1) listing instead -- the same
# idiom gather_network_logs already uses -- so that out-of-window files are
# never transferred at all.
#
# `oc cp` already requires tar in the target container, so the only added
# requirement is find. When either is missing we fall back to plain `oc cp` and
# say so, rather than collecting nothing.
#
# The container is optional; pass "" to use the pod's default container.
# Usage: copy_pod_dir_since <namespace> <pod> <container> <src-dir> <dest-dir> [label]
copy_pod_dir_since() {
	local ns="$1" pod="$2" container="$3" src="$4" dest="$5"
	local label="${6:-${pod}}"
	local predicate before after total
	local -a c_arg=()

	[ -n "${container}" ] && c_arg=(-c "${container}")

	mkdir -p "${dest}"

	if ! since_window_requested; then
		oc cp -n "${ns}" "${c_arg[@]}" "${pod}:${src}" "${dest}"
		return $?
	fi

	if ! oc exec -n "${ns}" "${pod}" "${c_arg[@]}" -- \
		sh -c 'command -v find >/dev/null 2>&1 && command -v tar >/dev/null 2>&1' 2>/dev/null; then
		echo "INFO: ${label}: find/tar unavailable in ${pod}; copying ${src} whole" >&2
		oc cp -n "${ns}" "${c_arg[@]}" "${pod}:${src}" "${dest}"
		since_report "${label}" "unfiltered-fallback" "all" "0"
		return $?
	fi

	total="$(oc exec -n "${ns}" "${pod}" "${c_arg[@]}" -- \
		sh -c "find '${src}' -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')"
	before="$(find "${dest}" -type f 2>/dev/null | wc -l)"

	predicate="$(since_find_predicate)"

	# shellcheck disable=SC2086
	oc exec -n "${ns}" "${pod}" "${c_arg[@]}" -- \
		sh -c "find '${src}' -type f ${predicate} -print0 2>/dev/null | tar czf - --null -T - 2>/dev/null" |
		tar xzf - -C "${dest}" 2>/dev/null

	after="$(find "${dest}" -type f 2>/dev/null | wc -l)"
	since_report "${label}" "find-newermt" "$((after - before))" \
		"$((${total:-0} - (after - before)))"
}

# Stream several directories out of a pod as one tarball, limited to files
# modified inside the window.
#
# The multi-directory sibling of copy_pod_dir_since, for collection that
# already tars a fixed set of log directories in one shot -- CNV's QEMU log
# collection does exactly that with
# `tar -cf - /var/log/libvirt/qemu/ /var/run/libvirt/qemu/log/ ...`.
#
# Missing directories are ignored, matching tar --ignore-failed-read, so this
# is safe to point at paths that only exist on some pods.
#
# Usage: pod_tar_dirs_since <namespace> <pod> <container> <dest-dir> <label> <src-dir>...
pod_tar_dirs_since() {
	local ns="$1" pod="$2" container="$3" dest="$4" label="$5"
	shift 5
	local predicate quoted=""
	local -a c_arg=()

	[ -n "${container}" ] && c_arg=(-c "${container}")
	mkdir -p "${dest}"

	local dir
	for dir in "$@"; do
		quoted+=" '${dir}'"
	done

	predicate="$(since_find_predicate)"

	# -prune-less: just let find skip what does not exist, as tar
	# --ignore-failed-read would.
	# shellcheck disable=SC2086
	oc exec -n "${ns}" "${pod}" "${c_arg[@]}" -- \
		sh -c "find ${quoted} -type f ${predicate} -print0 2>/dev/null | tar czf - --null -T - 2>/dev/null" |
		tar xzf - -C "${dest}" 2>/dev/null

	if since_window_requested; then
		since_report "${label}" "find-newermt" \
			"$(find "${dest}" -type f 2>/dev/null | wc -l)" "pre-cutoff"
	else
		since_report "${label}" "no-window" \
			"$(find "${dest}" -type f 2>/dev/null | wc -l)" "0"
	fi
}

# Drop JSON-lines records older than the cutoff, by an RFC3339 field.
#
# Audit events carry .requestReceivedTimestamp as an RFC3339 UTC string, so a
# plain string comparison orders them correctly. This is what makes the audit
# window exact rather than merely file-granular: the one rotated file that
# straddles the cutoff gets trimmed too.
#
# The filter is deliberately tolerant, because this runs over whatever the
# apiserver log directories hold. A line that is not JSON -- /var/log/etcd is
# plain text, not audit events -- is passed through verbatim, and so is a JSON
# object that has no such field. Only records that parse *and* carry the field
# *and* predate the cutoff are dropped, so this can never silently empty a
# file it did not understand.
#
# Passes everything through untouched when no window was requested, or when jq
# is unavailable.
#
# Usage: ... | trim_jsonl_since [field]
trim_jsonl_since() {
	local field="${1:-requestReceivedTimestamp}"

	if ! since_window_requested || ! command -v jq >/dev/null 2>&1; then
		cat
		return 0
	fi

	jq -crR --arg cutoff "${since_cutoff_rfc3339}" --arg field "${field}" '
		. as $line
		| (try fromjson catch null) as $o
		| if $o == null or ($o | type) != "object" then $line
		  elif (($o[$field] // "") == "") then $o
		  elif ($o[$field] >= $cutoff) then $o
		  else empty
		  end' 2>/dev/null
}

# Record what the window did to one piece of collection, so the result is
# auditable rather than mysterious.
since_report() {
	local label="$1" mechanism="$2" kept="$3" skipped="$4"

	mkdir -p "$(dirname "${SINCE_REPORT_PATH}")" 2>/dev/null || return 0
	printf '%s\t%s\t%s\tkept=%s\tskipped=%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${label}" "${mechanism}" "${kept}" "${skipped}" \
		>>"${SINCE_REPORT_PATH}" 2>/dev/null || true
}

# Write the header of the report once, naming the window in force.
since_report_header() {
	mkdir -p "$(dirname "${SINCE_REPORT_PATH}")" 2>/dev/null || return 0
	if [ -s "${SINCE_REPORT_PATH}" ]; then
		return 0
	fi
	{
		echo "# better-gather --since report"
		if since_window_requested; then
			echo "# window: everything at or after ${since_cutoff_rfc3339} (epoch ${since_cutoff_epoch})"
			echo "# requested as: MUST_GATHER_SINCE='${MUST_GATHER_SINCE:-}' MUST_GATHER_SINCE_TIME='${MUST_GATHER_SINCE_TIME:-}'"
		else
			echo "# window: none requested; everything collected"
		fi
		printf '# %s\t%s\t%s\t%s\t%s\n' "when" "what" "mechanism" "kept" "skipped"
	} >>"${SINCE_REPORT_PATH}" 2>/dev/null || true
}

export SINCE_REPORT_PATH
