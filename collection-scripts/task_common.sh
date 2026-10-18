#!/bin/bash
#
# Readable progress for a parallel gather, in the style of `sos report`.
#
# A must-gather run launches a couple of dozen collection scripts at once and
# lets their output interleave straight into must-gather.logs. The result is
# thousands of lines in no particular order, with no way to tell how far
# along the run is, which scripts have finished, or which did anything at
# all. Support cases routinely arrive with a log nobody has read.
#
# This gives the run the shape sos has had for years:
#
#   * the plan is printed before anything starts, so you know what is coming;
#   * each task reports [n/total] as it finishes, so progress is visible;
#   * each task's own output goes to its own file rather than into the
#     common stream;
#   * a summary at the end says what succeeded, what collected nothing, and
#     what failed.
#
# Deliberately self-contained so it can be vendored into the CNV and ODF
# forks the same way since_common.sh is -- see hack/sync-since-lib.sh.
#
# Usage:
#
#   source task_common.sh
#   task_plan etcd monitoring olm          # announce, sets the total
#   task_run etcd /usr/bin/gather_etcd     # backgrounds it
#   task_run monitoring /usr/bin/gather_monitoring
#   task_wait                              # wait for all of them
#   task_summary                           # print the table, set the rc

TASK_BASE_PATH="${TASK_BASE_PATH:-${BASE_COLLECTION_PATH:-/must-gather}}"
TASK_LOG_DIR="${TASK_LOG_DIR:-${TASK_BASE_PATH}/task-logs}"
TASK_RESULTS="${TASK_RESULTS:-${TASK_BASE_PATH}/task-results.tsv}"
TASK_STARTED="${TASK_STARTED:-${TASK_BASE_PATH}/task-started.tsv}"

# A clean copy of the progress, without oc's disk-usage checker interleaved
# into it. oc starts that checker as a sibling process writing to the same
# container stdout every five seconds, so the live stream cannot be cleaned
# up from in here -- but the archive can have a readable record.
TASK_PROGRESS_LOG="${TASK_PROGRESS_LOG:-${TASK_BASE_PATH}/gather-progress.log}"

# How often to say what is still running, in seconds. During a long task
# there is otherwise nothing but the checker's output for minutes at a time,
# which reads as though the gather has hung.
TASK_HEARTBEAT="${TASK_HEARTBEAT:-30}"
TASK_STOP="${TASK_STOP:-${TASK_BASE_PATH}/.task-stop}"

# Patterns a collection script uses to say "the thing I collect is not here".
# Matching one of these with a zero exit means the task ran fine and had
# nothing to do, which is worth distinguishing from actually collecting
# something -- most of a default gather is no-ops on any given cluster.
TASK_NOOP_PATTERN="${TASK_NOOP_PATTERN:-not detected|not installed|[Ss]kipping|not found|no such|is not present|No resources found}"

task_pids=()
task_total=0
task_started_at=0

# Announce what is about to run. Everything after this is one of these names.
task_plan() {
	task_total=$#
	task_started_at="$(date -u +%s)"

	mkdir -p "${TASK_LOG_DIR}"
	: >"${TASK_RESULTS}"
	: >"${TASK_STARTED}"
	: >"${TASK_PROGRESS_LOG}"
	rm -f "${TASK_STOP}"

	echo
	echo "Collecting with ${task_total} task(s)."
	# Wrap the names rather than printing one per line: two dozen names fit
	# in a few lines and are easier to scan as a block.
	printf '%s\n' "$@" | sort | paste -sd' ' - | fold -s -w 76 |
		sed 's/^/  /'
	echo
	echo "Per-task output goes to ${TASK_LOG_DIR}/, not into this log."
	echo
}

# Run one task in the background, recording how it went.
#
#   task_run <name> <command> [args...]
task_run() {
	local name="$1"
	shift
	_task_exec "${name}" "$@" &
	task_pids+=($!)
}

_task_exec() {
	local name="$1"
	shift
	local log="${TASK_LOG_DIR}/${name//\//_}.log"
	local start rc elapsed state detail=""

	start="$(date -u +%s)"
	printf '%s\t%s\n' "${name}" "${start}" >>"${TASK_STARTED}" 2>/dev/null || true
	"$@" >"${log}" 2>&1
	rc=$?
	elapsed=$(($(date -u +%s) - start))

	if [ "${rc}" -eq 127 ]; then
		# The script is not in this image at all. That is not a collection
		# failure -- it happens when a newer gather runs against an older
		# must-gather image, which is exactly what the release branches
		# exist to avoid -- so say so rather than reporting it as broken.
		state="missing"
		detail="not present in this image"
	elif [ "${rc}" -ne 0 ]; then
		state="failed"
		detail="rc=${rc}"
	elif [ ! -s "${log}" ] || grep -Eqi "${TASK_NOOP_PATTERN}" "${log}"; then
		state="no-op"
		detail="$(grep -Eoim1 "${TASK_NOOP_PATTERN}[^.]*" "${log}" 2>/dev/null | head -1)"
		[ -n "${detail}" ] || detail="produced no output"
	else
		state="ok"
	fi

	_task_record "${name}" "${state}" "${rc}" "${elapsed}" "${detail}"
}

# Append one result and print progress.
#
# Serialised with flock where it works, so that two tasks finishing at the
# same moment cannot both claim the same position in the count. flock is in
# util-linux and is present in all three must-gather images, but this does
# not depend on that: if it is missing, or if the call itself fails, the
# record is written directly instead.
#
# Whether the record landed is checked by looking for it, not by trusting
# flock's exit status. Losing a result silently would be much worse than a
# duplicated number in the progress column -- the summary would under-count
# and the drift warning would fire for the wrong reason.
_task_record() {
	local name="$1" state="$2" rc="$3" elapsed="$4" detail="$5"

	if command -v flock >/dev/null 2>&1; then
		flock "${TASK_RESULTS}" bash -c \
			"$(declare -f _task_emit); _task_emit \"\$@\"" _ \
			"${TASK_RESULTS}" "${task_total}" "${name}" "${state}" \
			"${rc}" "${elapsed}" "${detail}" 2>/dev/null || true
	fi

	if ! grep -qF "${name}"$'\t' "${TASK_RESULTS}" 2>/dev/null; then
		_task_emit "${TASK_RESULTS}" "${task_total}" "${name}" "${state}" \
			"${rc}" "${elapsed}" "${detail}"
	fi
}

_task_emit() {
	local results="$1" total="$2" name="$3" state="$4" rc="$5" elapsed="$6" detail="$7"
	local position width line

	printf '%s\t%s\t%s\t%s\t%s\n' \
		"${name}" "${state}" "${rc}" "${elapsed}" "${detail}" >>"${results}"

	position="$(wc -l <"${results}" | tr -d '[:space:]')"
	width="${#total}"
	line="$(printf '  [%*d/%d] %-42s %-7s %5ds' \
		"${width}" "${position}" "${total}" "${name}" "${state}" "${elapsed}")"
	printf '%s\n' "${line}"
	printf '%s\n' "${line}" >>"${TASK_PROGRESS_LOG}" 2>/dev/null || true
}

# Say what is still running and for how long.
#
# Without this a slow task leaves minutes of dead air, filled only by oc's
# disk-usage checker, and the run looks hung. This is the equivalent of the
# "[Running: ...]" column sos keeps on screen.
# Sleeps in one-second steps rather than one long one. Killing the loop does
# not kill a `sleep` it is blocked in, and that orphan keeps the container's
# stdout open after collection has finished -- long enough to stall anything
# reading the log to EOF.
_task_heartbeat() {
	local now running count name start waited=0
	while [ ! -f "${TASK_STOP}" ]; do
		sleep 1
		waited=$((waited + 1))
		if [ "${waited}" -lt "${TASK_HEARTBEAT}" ]; then
			continue
		fi
		waited=0
		now="$(date -u +%s)"
		running=""
		count=0
		while IFS=$'\t' read -r name start; do
			[ -n "${name}" ] || continue
			grep -qF "${name}"$'\t' "${TASK_RESULTS}" 2>/dev/null && continue
			running="${running}${running:+, }${name} $(_task_duration "$((now - start))")"
			count=$((count + 1))
		done <"${TASK_STARTED}"

		[ "${count}" -gt 0 ] || continue
		_task_say "  ... $(wc -l <"${TASK_RESULTS}" | tr -d '[:space:]')/${task_total} done; still running: ${running}"
	done
}

_task_say() {
	printf '%s\n' "$1"
	printf '%s\n' "$1" >>"${TASK_PROGRESS_LOG}" 2>/dev/null || true
}

# Wait for everything task_run started, reporting progress while we do.
task_wait() {
	local heartbeat_pid=""

	if [ "${#task_pids[@]}" -eq 0 ]; then
		return 0
	fi

	if [ "${TASK_HEARTBEAT}" -gt 0 ]; then
		_task_heartbeat &
		heartbeat_pid=$!
	fi

	wait "${task_pids[@]}" 2>/dev/null || true
	task_pids=()

	if [ -n "${heartbeat_pid}" ]; then
		: >"${TASK_STOP}"
		wait "${heartbeat_pid}" 2>/dev/null || true
		rm -f "${TASK_STOP}"
	fi
}

# Print the closing summary. Returns non-zero if any task failed, so a caller
# can propagate that if it wants to; `gather` deliberately does not, because
# must-gather collects what it can.
task_summary() {
	local total ok noop failed missing elapsed
	local name state rc secs detail

	[ -s "${TASK_RESULTS}" ] || {
		echo "No tasks were run."
		return 0
	}

	total="$(wc -l <"${TASK_RESULTS}" | tr -d '[:space:]')"

	# The plan is declared separately from the task_run calls, so say so if
	# the two have drifted rather than quietly reporting a different number
	# from the one announced at the start.
	if [ "${task_total}" -gt 0 ] && [ "${total}" -ne "${task_total}" ]; then
		printf 'WARNING: %s task(s) ran but %s were planned; the plan and the\n' \
			"${total}" "${task_total}"
		printf '         task_run calls have drifted apart.\n'
	fi
	ok="$(awk -F'\t' '$2=="ok"' "${TASK_RESULTS}" | wc -l)"
	noop="$(awk -F'\t' '$2=="no-op"' "${TASK_RESULTS}" | wc -l)"
	failed="$(awk -F'\t' '$2=="failed"' "${TASK_RESULTS}" | wc -l)"
	missing="$(awk -F'\t' '$2=="missing"' "${TASK_RESULTS}" | wc -l)"
	elapsed=$(($(date -u +%s) - task_started_at))

	echo
	echo "----------------------------------------------------------------"
	printf '%s task(s): %s ok, %s no-op, %s failed' \
		"${total}" "${ok}" "${noop}" "${failed}"
	[ "${missing}" -eq 0 ] || printf ', %s missing' "${missing}"
	printf ', in %s\n' "$(_task_duration "${elapsed}")"

	if [ "${failed}" -gt 0 ]; then
		echo
		echo "  failed:"
		while IFS=$'\t' read -r name state rc secs detail; do
			[ "${state}" = "failed" ] || continue
			printf '    %-40s rc=%-4s %s\n' "${name}" "${rc}" \
				"${TASK_LOG_DIR}/${name//\//_}.log"
		done <"${TASK_RESULTS}"
		echo
		echo "  A non-zero status is common and often harmless: oc adm inspect"
		echo "  exits 1 when an optional resource is absent. Data already"
		echo "  collected is still written."
	fi

	if [ "${missing}" -gt 0 ]; then
		echo
		echo "  not present in this image:"
		while IFS=$'\t' read -r name state rc secs detail; do
			[ "${state}" = "missing" ] || continue
			printf '    %s\n' "${name}"
		done <"${TASK_RESULTS}"
		echo
		echo "  This gather script expects collection scripts the image does"
		echo "  not have, which means the two are from different releases."
		echo "  Use the image tag matching your cluster, e.g. :4.18."
	fi

	if [ "${noop}" -gt 0 ]; then
		echo
		echo "  collected nothing (not present on this cluster):"
		while IFS=$'\t' read -r name state rc secs detail; do
			[ "${state}" = "no-op" ] || continue
			printf '    %-40s %s\n' "${name}" "${detail}"
		done <"${TASK_RESULTS}"
	fi

	echo
	echo "  slowest:"
	sort -t$'\t' -k4 -rn "${TASK_RESULTS}" | head -5 |
		while IFS=$'\t' read -r name state rc secs detail; do
			printf '    %-40s %5ds  %s\n' "${name}" "${secs}" "${state}"
		done

	echo
	echo "  full output: ${TASK_LOG_DIR}/"
	echo "  machine readable: ${TASK_RESULTS}"
	echo "----------------------------------------------------------------"

	[ "${failed}" -eq 0 ]
}

_task_duration() {
	local s="$1"
	if [ "${s}" -lt 60 ]; then
		printf '%ds' "${s}"
	elif [ "${s}" -lt 3600 ]; then
		printf '%dm%02ds' "$((s / 60))" "$((s % 60))"
	else
		printf '%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
	fi
}

# Exported so the functions survive an `xargs ... sh -c` fan-out, for the
# same reason since_common.sh exports its own.
if [ -n "${BASH_VERSION:-}" ]; then
	export -f task_plan task_run task_wait task_summary
	export -f _task_exec _task_record _task_emit _task_duration
	export -f _task_heartbeat _task_say
fi
export TASK_BASE_PATH TASK_LOG_DIR TASK_RESULTS TASK_NOOP_PATTERN
export TASK_STARTED TASK_PROGRESS_LOG TASK_HEARTBEAT TASK_STOP
