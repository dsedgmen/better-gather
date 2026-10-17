#!/bin/bash

# duration_to_node_logs_since and get_since_cutoff live in
# since_common.sh so the library is self-contained and can be vendored
# into the CNV and ODF forks. The dependency runs one way only.
# shellcheck source=collection-scripts/since_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/since_common.sh"

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

get_log_collection_args() {
	# validation of MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME is done by the
	# caller (oc adm must-gather) so it's safe to use the values as they are.
	log_collection_args=""

	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		log_collection_args=--since="${MUST_GATHER_SINCE}"
	fi
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		# shellcheck disable=SC2034
		log_collection_args=--since-time="${MUST_GATHER_SINCE_TIME}"
	fi


	# REDUCE_LOGS: unset = default (--rotated-pod-logs). If set, only skip_rotated_logs is allowed.
	rotated_pod_logs_arg="--rotated-pod-logs"

	if [ -n "${REDUCE_LOGS:-}" ]; then
		case "${REDUCE_LOGS}" in
		skip_rotated_logs)
			rotated_pod_logs_arg=""
			;;
		*)
			echo "ERROR: REDUCE_LOGS must be unset or skip_rotated_logs (got: [${REDUCE_LOGS}])." >&2
			exit 1
			;;
		esac
	fi

	# oc adm node-logs `--since` parameter is not the same as oc adm inspect `--since`.
	# it takes a simplified duration in the form of '(+|-)[0-9]+(s|m|h|d)' or
	# an ISO formatted time. since MUST_GATHER_SINCE and MUST_GATHER_SINCE_TIME
	# are formatted differently, we re-format them so they can be used
	# transparently by node-logs invocations.
	node_log_collection_args=""

	# shellcheck disable=SC2001
	if [ -n "${MUST_GATHER_SINCE:-}" ]; then
		# node-logs takes a single '(+|-)[0-9]+(s|m|h|d)' component, so a multi-component
		# duration has to be collapsed into one. Keeping only the first
		# component, as this did, silently narrows the window: 2h30m
		# becomes -2h and 500ms becomes -500m, read as 500 minutes.
		since=$(duration_to_node_logs_since "${MUST_GATHER_SINCE}")
		node_log_collection_args=--since="-${since}"
	fi
	# shellcheck disable=SC2034
	if [ -n "${MUST_GATHER_SINCE_TIME:-}" ]; then
		iso_time=$(echo "${MUST_GATHER_SINCE_TIME}" | sed 's/T/ /; s/Z//')
		node_log_collection_args=--since="${iso_time}"
	fi
}
