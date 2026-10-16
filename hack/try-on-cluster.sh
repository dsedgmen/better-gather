#!/usr/bin/env bash
#
# Run the working tree's collection scripts against a live cluster without
# building or pushing an image.
#
# The scripts are tarred up, carried into a stock must-gather pod, unpacked
# to /tmp/better-gather and run from there. Because every collection script
# sources "$(dirname "$0")/common.sh", running them from that directory picks
# up the modified common.sh and since_common.sh automatically.
#
# Turns a change-test cycle from "build, push, pull, run" into about a minute.
#
#   hack/try-on-cluster.sh gather_audit_logs --since 30m
#   hack/try-on-cluster.sh gather_audit_logs --since 30m -- --force
#   hack/try-on-cluster.sh --dry-run gather_network_logs --since 1h
#
# Why base64: oc joins everything after `--` with spaces and drops the result
# into an *unquoted* heredoc (pkg/cli/admin/mustgather/mustgather.go,
# buildPodCommand), so the outer shell would expand $VAR and $(...) in a
# plain inline script. base64's alphabet gives it nothing to act on.

set -eu -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r PROJECT_ROOT
declare -r POD_DIR="/tmp/better-gather"

usage() {
	sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

dry_run=false
script=""
declare -a oc_args=()
declare -a script_args=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help) usage 0 ;;
	--dry-run)
		dry_run=true
		shift
		;;
	--)
		shift
		script_args=("$@")
		break
		;;
	--since | --since-time | --dest-dir | --timeout | --node-name | --run-namespace | --image)
		oc_args+=("$1=$2")
		shift 2
		;;
	--*) # any other oc flag, passed through as given
		oc_args+=("$1")
		shift
		;;
	*)
		if [[ -z "$script" ]]; then
			script="$1"
		else
			script_args+=("$1")
		fi
		shift
		;;
	esac
done

if [[ -z "$script" ]]; then
	echo "ERROR: name a collection script to run, e.g. gather_audit_logs" >&2
	usage 1
fi

if [[ ! -f "$PROJECT_ROOT/collection-scripts/$script" ]]; then
	echo "ERROR: collection-scripts/$script does not exist" >&2
	exit 1
fi

payload="$(tar czf - -C "$PROJECT_ROOT" collection-scripts | base64 -w0)"

if ! [[ "$payload" =~ ^[A-Za-z0-9+/=]+$ ]]; then
	echo "ERROR: payload is not pure base64; oc's heredoc would mangle it" >&2
	exit 1
fi

# Single argv element, so oc's strings.Join leaves it intact.
remote_cmd="echo '${payload}' | base64 -d >/tmp/bg.tgz"
remote_cmd+=" && mkdir -p ${POD_DIR}"
remote_cmd+=" && tar xzf /tmp/bg.tgz -C ${POD_DIR} --strip-components=1"
remote_cmd+=" && chmod +x ${POD_DIR}/*"
remote_cmd+=" && echo 'INFO: running ${script} from the working tree'"
remote_cmd+=" && ${POD_DIR}/${script}"
for arg in ${script_args+"${script_args[@]}"}; do
	remote_cmd+=" ${arg}"
done

if [[ "$dry_run" == true ]]; then
	echo "oc adm must-gather ${oc_args[*]-} -- <${#payload} char payload>"
	echo
	echo "--- in-pod command (payload elided) ---"
	echo "${remote_cmd/${payload}/<base64 of collection-scripts/>}"
	exit 0
fi

echo "INFO: carrying $(tar tzf <(base64 -d <<<"$payload") | grep -c . ) files into the pod"
exec oc adm must-gather ${oc_args+"${oc_args[@]}"} -- "$remote_cmd"
