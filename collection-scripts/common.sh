#!/bin/bash

function get_operator_ns() {
	# shellcheck disable=SC2155,SC2116,SC2086
	local operator_name=$(echo \"$1\")
	# shellcheck disable=SC2034,SC2116,SC2028
	cmd="$(echo "oc get subs -A -o template --template '{{range .items}}{{if eq .spec.name ""${operator_name}""}}{{.metadata.namespace}}{{\"\\n\"}}{{end}}{{end}}'")"
	operator_ns="$(eval "$cmd")"

	if [ -z "${operator_ns}" ]; then
		echo "INFO: ${operator_name} not detected. Skipping."
		exit 0
	fi

	if [[ "$(echo "${operator_ns}" | wc -l)" -gt 1 ]]; then
		echo "ERROR: found more than one ${operator_name} subscription. Exiting."
		exit 1
	fi
}

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

get_log_collection_args() {
	# validation of MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME is done by the
	# caller (oc adm must-gather) so it's safe to use the values as they are.
	log_collection_args=""

	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		log_collection_args=--since="${MUST_GATHER_SINCE}"
	fi
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		log_collection_args=--since-time="${MUST_GATHER_SINCE_TIME}"
	fi


	# REDUCE_LOGS: unset = defaults. Comma or space separated list of:
	#   skip_rotated_logs     - omit --rotated-pod-logs from oc adm inspect
	#   compress_service_logs - gzip host service / Windows node logs (see gather_service_logs_util, gather_windows_node_logs)
	#   compress_logs         - gzip collected .log files >=10MB after gather (before rsync)

	rotated_pod_logs_arg="--rotated-pod-logs"
	compress_service_logs=""
	compress_after_gather=""

	if [ -n "${REDUCE_LOGS:-}" ]; then
		# Normalize commas to spaces, then validate each option.
		# Intentional word-splitting of comma/space separated options.
		# shellcheck disable=SC2086
		for reduce_logs_option in ${REDUCE_LOGS//,/ }; do
			case "${reduce_logs_option}" in
			skip_rotated_logs)
				rotated_pod_logs_arg=""
				;;
			compress_service_logs)
				compress_service_logs=true
				;;
			compress_logs)
				compress_after_gather=true
				;;
			"")
				;;
			*)
				echo "ERROR: REDUCE_LOGS unknown value '${reduce_logs_option}'. Allowed: skip_rotated_logs, compress_service_logs, compress_logs (got: [${REDUCE_LOGS}])." >&2
				exit 1
				;;
			esac
		done
	fi

	# oc adm node-logs `--since` parameter is not the same as oc adm inspect `--since`.
	# it takes a simplified duration in the form of '(+|-)[0-9]+(s|m|h|d)' or
	# an ISO formatted time. since MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME
	# are formatted differently, we re-format them so they can be used
	# transparently by node-logs invocations.
	node_log_collection_args=""

	# shellcheck disable=SC2001
	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		# node-logs accepts a single '(+|-)[0-9]+(s|m|h|d)' component, so a
		# multi-component duration has to be collapsed into one. Round the
		# whole duration *up* to its largest unit rather than truncating to
		# the first component: truncating turns 2h30m into 2h and silently
		# drops the oldest 30 minutes of the window the user asked for.
		since=$(duration_to_node_logs_since "${MUST_GATHER_SINCE}")
		node_log_collection_args=--since="-${since}"
	fi
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		iso_time=$(echo "${MUST_GATHER_SINCE_TIME}" | sed 's/T/ /; s/Z//')
		node_log_collection_args=--since="${iso_time}"
	fi

	# Export globals used by gather_* scripts that source this file (also satisfies ShellCheck SC2034):
	# log_collection_args, node_log_collection_args, rotated_pod_logs_arg, compress_service_logs, compress_after_gather.
	export log_collection_args node_log_collection_args rotated_pod_logs_arg compress_service_logs compress_after_gather
}

# Compress collected .log / .log.* files larger than 10MB (skip already-gzipped).
# Uses gzip -1 (fastest) with 2 parallel jobs.
compress_logs() {
	local target_dir="${1:-/must-gather}"

	echo "Compressing collected logs in parallel (jobs=2)..."
	# Find large logs, then gzip up to 2 at a time.
	# -print0 / xargs -0: safe with spaces in paths
	# xargs -r: skip gzip if find matches nothing
	find "${target_dir}" \
		\( -name '*.log' -o -name '*.log.*' \) \
		! -name '*.gz' \
		-size +10M \
		-print0 |
		xargs -0 -r -P 2 gzip -1
	echo "Compression complete."
}
