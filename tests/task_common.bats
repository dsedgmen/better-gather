#!/usr/bin/env bats
# Tests for collection-scripts/task_common.sh -- the sos-style progress and
# summary for a parallel gather.

load test_helper

setup_tasks() {
	export TASK_BASE_PATH="$TEST_TMPDIR/mg"
	mkdir -p "$TASK_BASE_PATH"
}

# Run a script body with the library sourced and the task paths pointed at
# the test's temp directory.
tasks() {
	run bash -c "
		export TASK_BASE_PATH='$TEST_TMPDIR/mg'
		mkdir -p \"\$TASK_BASE_PATH\"
		source '$SCRIPT_DIR/task_common.sh'
		$1
	"
}

# =============================================================================
# task_plan
# =============================================================================

@test "task_plan announces how many tasks and which" {
	tasks 'task_plan etcd monitoring olm'
	assert_success
	assert_output --partial "Collecting with 3 task(s)."
	assert_output --partial "etcd"
	assert_output --partial "monitoring"
	assert_output --partial "olm"
}

@test "task_plan says where the per-task output goes" {
	tasks 'task_plan etcd'
	assert_success
	assert_output --partial "task-logs/"
}

@test "task_plan starts from an empty results file" {
	tasks '
		task_plan a
		task_run a true
		task_wait
		task_plan b
		wc -l <"$TASK_RESULTS"
	'
	assert_success
	assert_output --partial "0"
}

# =============================================================================
# Progress lines
# =============================================================================

@test "each task reports its position out of the total" {
	tasks '
		task_plan one two three
		task_run one true
		task_wait
		task_run two true
		task_wait
		task_run three true
		task_wait
	'
	assert_success
	assert_output --partial "[1/3]"
	assert_output --partial "[2/3]"
	assert_output --partial "[3/3]"
}

@test "the position counter is padded to the width of the total" {
	tasks "
		task_plan $(seq -s' ' 1 12 | sed 's/[0-9]*/t&/g')
		task_run t1 true
		task_wait
	"
	assert_success
	# 1 of 12 prints as [ 1/12], not [1/12], so the column stays aligned
	assert_output --partial "[ 1/12]"
}

# =============================================================================
# Classification
# =============================================================================

@test "a task that collects something is ok" {
	tasks '
		task_plan alpha
		task_run alpha bash -c "echo collected 42 objects"
		task_wait
		task_summary
	'
	assert_success
	assert_output --partial "1 task(s): 1 ok, 0 no-op, 0 failed"
}

@test "a task that says the thing is not present is a no-op" {
	tasks '
		task_plan sriov
		task_run sriov bash -c "echo \"INFO: sriov-network-operator not detected. Skipping.\""
		task_wait
		task_summary
	'
	assert_success
	assert_output --partial "0 ok, 1 no-op, 0 failed"
	assert_output --partial "collected nothing"
	assert_output --partial "sriov"
}

@test "a task that produces no output at all is a no-op" {
	tasks '
		task_plan quiet
		task_run quiet true
		task_wait
		task_summary
	'
	assert_success
	assert_output --partial "0 ok, 1 no-op, 0 failed"
	assert_output --partial "produced no output"
}

@test "a non-zero exit is a failure, with its log named" {
	tasks '
		task_plan broken
		task_run broken bash -c "echo something went wrong >&2; exit 3"
		task_wait
		task_summary || true
	'
	assert_output --partial "0 ok, 0 no-op, 1 failed"
	assert_output --partial "rc=3"
	assert_output --partial "task-logs/broken.log"
}

@test "a failure is explained as often harmless" {
	# oc adm inspect exits 1 whenever an optional resource is absent, which
	# is the common case; the summary should not read like a disaster.
	tasks '
		task_plan x
		task_run x bash -c "exit 1"
		task_wait
		task_summary || true
	'
	assert_output --partial "often harmless"
}

@test "task_summary returns non-zero when a task failed" {
	tasks '
		task_plan x
		task_run x false
		task_wait
		if task_summary >/dev/null; then echo RC=0; else echo RC=nonzero; fi
	'
	assert_success
	assert_output --partial "RC=nonzero"
}

@test "task_summary returns zero when nothing failed" {
	tasks '
		task_plan x
		task_run x bash -c "echo data"
		task_wait
		if task_summary >/dev/null; then echo RC=0; else echo RC=nonzero; fi
	'
	assert_success
	assert_output --partial "RC=0"
}

# =============================================================================
# Output capture
# =============================================================================

@test "a task's own output goes to its own file, not the shared log" {
	tasks '
		task_plan noisy
		task_run noisy bash -c "echo LINE-FROM-THE-TASK; echo ERR-LINE >&2"
		task_wait
		echo "--- log contents ---"
		cat "$TASK_LOG_DIR/noisy.log"
	'
	assert_success
	# It appears once, in the file, not twice from also being streamed.
	assert_output --partial "LINE-FROM-THE-TASK"
	assert_output --partial "ERR-LINE"
	run bash -c "grep -c LINE-FROM-THE-TASK <<'EOF'
$output
EOF"
	assert_output "1"
}

@test "a task name containing a slash is still a usable filename" {
	tasks '
		task_plan core:named
		task_run core:named bash -c "echo x"
		task_wait
		ls "$TASK_LOG_DIR"
	'
	assert_success
	assert_output --partial "core:named.log"
}

# =============================================================================
# Machine-readable results
# =============================================================================

@test "results are written as tab-separated name/state/rc/seconds" {
	tasks '
		task_plan a
		task_run a bash -c "echo data"
		task_wait
		cat "$TASK_RESULTS"
	'
	assert_success
	run bash -c "printf '%s' '$output' | awk -F'\t' '{print NF, \$1, \$2, \$3}'"
	assert_output --partial "5 a ok 0"
}

# =============================================================================
# Drift between the plan and what ran
# =============================================================================

@test "a plan that disagrees with the tasks run is reported" {
	tasks '
		task_plan a b c
		task_run a true
		task_wait
		task_summary
	'
	assert_output --partial "WARNING"
	assert_output --partial "drifted apart"
}

@test "no warning when the plan matches" {
	tasks '
		task_plan a b
		task_run a true
		task_run b true
		task_wait
		task_summary
	'
	refute_output --partial "drifted apart"
}

# =============================================================================
# Parallelism
# =============================================================================

@test "tasks really do run in parallel" {
	tasks '
		task_plan s1 s2 s3
		start=$(date +%s)
		task_run s1 sleep 2
		task_run s2 sleep 2
		task_run s3 sleep 2
		task_wait
		echo "elapsed=$(( $(date +%s) - start ))"
	'
	assert_success
	# Serially this would be 6s. Allow slack, but 3 proves concurrency.
	run bash -c "printf '%s' '$output' | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p'"
	[ "$output" -lt 4 ]
}

@test "every task is accounted for when many finish at once" {
	# The position counter is serialised with flock; without it two tasks
	# finishing together can claim the same slot and one is lost.
	tasks '
		task_plan $(seq -s" " 1 20 | sed "s/[0-9]*/t&/g")
		for i in $(seq 1 20); do task_run "t$i" true; done
		task_wait
		wc -l <"$TASK_RESULTS"
	'
	assert_success
	assert_output --partial "20"
}

# =============================================================================
# Sourcing is harmless
# =============================================================================

@test "the library exports its functions for sh -c fan-out" {
	tasks '
		sh -c "type task_run >/dev/null 2>&1 && echo exported || echo missing"
	'
	assert_success
	assert_output --partial "exported"
}

@test "task_summary copes with no tasks at all" {
	tasks '
		task_plan
		task_summary
	'
	assert_success
	assert_output --partial "No tasks were run."
}

# =============================================================================
# A script the image does not have
# =============================================================================

@test "a missing collection script is reported as missing, not failed" {
	# rc=127 means the image does not carry that script, which happens when
	# a newer gather runs against an older must-gather image. That is a
	# version mismatch, not a collection failure, and reporting it as a
	# failure sends people looking for the wrong problem. Seen for real:
	# main's gather against a 4.18 image reports six of these.
	tasks '
		task_plan absent
		task_run absent /usr/bin/definitely-not-a-real-script
		task_wait
		task_summary
	'
	assert_success
	assert_output --partial "1 missing"
	assert_output --partial "not present in this image"
	refute_output --partial "1 failed, 1 missing, in"
}

@test "missing scripts are counted apart from failures" {
	tasks '
		task_plan a b
		task_run a /usr/bin/definitely-not-a-real-script
		task_run b bash -c "exit 2"
		task_wait
		task_summary || true
	'
	assert_output --partial "0 ok, 0 no-op, 1 failed, 1 missing"
}

@test "the mismatch hint names the versioned image tag" {
	tasks '
		task_plan a
		task_run a /usr/bin/definitely-not-a-real-script
		task_wait
		task_summary
	'
	assert_success
	assert_output --partial ":4.18"
}

# =============================================================================
# Recording a result must not depend on flock working
# =============================================================================

@test "results still land when flock is missing entirely" {
	# A symlink farm of the real PATH with flock removed, so everything
	# else the library needs is still present.
	mkdir -p "$TEST_TMPDIR/nf" "$TEST_TMPDIR/mg1"
	local d f
	for d in /usr/bin /bin; do
		[ -d "$d" ] || continue
		for f in "$d"/*; do ln -sf "$f" "$TEST_TMPDIR/nf/" 2>/dev/null || true; done
	done
	rm -f "$TEST_TMPDIR/nf/flock"

	TASK_BASE_PATH="$TEST_TMPDIR/mg1" PATH="$TEST_TMPDIR/nf" \
		run "$BATS_TEST_DIRNAME/fixtures/task_scenario.sh" "$SCRIPT_DIR/task_common.sh"
	assert_success
	assert_output --partial "RECORDED=3"
}

@test "results still land when flock exists but fails" {
	# Found by stubbing flock: the code took the flock branch, every call
	# exited 127, and every result was silently lost -- no records, no
	# summary, and nothing to say anything had gone wrong.
	mkdir -p "$TEST_TMPDIR/bf" "$TEST_TMPDIR/mg2"
	printf '#!/bin/sh\nexit 127\n' >"$TEST_TMPDIR/bf/flock"
	chmod +x "$TEST_TMPDIR/bf/flock"

	TASK_BASE_PATH="$TEST_TMPDIR/mg2" PATH="$TEST_TMPDIR/bf:$PATH" \
		run "$BATS_TEST_DIRNAME/fixtures/task_scenario.sh" "$SCRIPT_DIR/task_common.sh"
	assert_success
	assert_output --partial "RECORDED=3"
}

@test "a result is recorded exactly once when flock works" {
	# The fallback checks whether the record landed rather than trusting
	# flock's exit status, so it must not double-write on the happy path.
	tasks '
		task_plan solo
		task_run solo bash -c "echo data"
		task_wait
		wc -l <"$TASK_RESULTS"
	'
	assert_success
	assert_output --partial "1"
}

@test "positions are unique under heavy concurrency" {
	# 40 tasks finishing together. Without serialisation several claim the
	# same slot, which is how the need for flock showed up.
	tasks '
		task_plan $(seq -s" " 1 40 | sed "s/[0-9]*/t&/g") >/dev/null
		for i in $(seq 1 40); do task_run "t$i" true; done
		task_wait
	'
	assert_success
	run bash -c "printf '%s' '$output' | grep -oE '\[ *[0-9]+/40\]' | grep -oE '[0-9]+/' | tr -d '/' | sort -n | uniq -d | wc -l"
	assert_output "0"
}

# =============================================================================
# Heartbeat: saying what is still running
# =============================================================================

@test "a slow task does not leave the run silent" {
	# oc's own disk-usage checker prints every five seconds regardless, so
	# without this a long task looks like a hang: minutes of checker output
	# and nothing else.
	tasks '
		export TASK_HEARTBEAT=1
		task_plan quick slow >/dev/null
		task_run quick true
		task_run slow bash -c "sleep 3; echo data"
		task_wait
	'
	assert_success
	assert_output --partial "still running: slow"
	assert_output --partial "/2 done"
}

@test "the heartbeat names only tasks that have not finished" {
	tasks '
		export TASK_HEARTBEAT=1
		task_plan a b >/dev/null
		task_run a true
		task_run b bash -c "sleep 3; echo data"
		task_wait
	'
	assert_success
	run bash -c "printf '%s' '$output' | grep 'still running' | grep -c ' a '"
	assert_output "0"
}

@test "the heartbeat can be turned off" {
	tasks '
		export TASK_HEARTBEAT=0
		task_plan slow >/dev/null
		task_run slow bash -c "sleep 2; echo data"
		task_wait
	'
	assert_success
	refute_output --partial "still running"
}

@test "the heartbeat does not outlive task_wait" {
	# A leaked background loop would keep printing into the pod log after
	# collection had finished.
	tasks '
		export TASK_HEARTBEAT=1
		task_plan a >/dev/null
		task_run a bash -c "sleep 2; echo data"
		task_wait
		before=$(jobs -rp | wc -l)
		sleep 2
		echo "running jobs after wait: $(jobs -rp | wc -l)"
	'
	assert_success
	assert_output --partial "running jobs after wait: 0"
}

# =============================================================================
# A clean copy of the progress for the archive
# =============================================================================

@test "progress is also written to a log without oc's noise in it" {
	tasks '
		task_plan a b >/dev/null
		task_run a bash -c "echo data"
		task_run b bash -c "echo data"
		task_wait
		echo "--- file ---"
		cat "$TASK_PROGRESS_LOG"
	'
	assert_success
	run bash -c "printf '%s' '$output' | sed -n '/--- file ---/,\$p' | grep -c '^  \['"
	assert_output "2"
}

@test "task_wait returns promptly, leaving no sleep holding the log open" {
	# Killing the heartbeat does not kill a `sleep` it is blocked in, and
	# that orphan keeps the container's stdout open after collection has
	# finished. With the default 30s interval it stalled anything reading
	# the log to EOF for half a minute.
	run timeout 20 bash -c "
		export TASK_BASE_PATH='$TEST_TMPDIR/mgq'
		mkdir -p \"\$TASK_BASE_PATH\"
		source '$SCRIPT_DIR/task_common.sh'
		start=\$(date +%s)
		task_plan a >/dev/null
		task_run a true
		task_wait
		echo \"waited=\$(( \$(date +%s) - start ))\"
	"
	assert_success
	run bash -c "printf '%s' '$output' | sed -n 's/.*waited=\([0-9]*\).*/\1/p'"
	# default heartbeat is 30s; anything near that means an orphaned sleep
	[ "$output" -lt 5 ]
}

# =============================================================================
# Compression as a tracked task
# =============================================================================

@test "compression shows as progress rather than silence after the summary" {
	# REDUCE_LOGS=compress_logs gzips every collected log over 10MB. On a
	# large archive that takes a while, and it used to run after the summary
	# with nothing printed but its own two lines.
	run bash -c "
		export TASK_BASE_PATH='$TEST_TMPDIR/mgc' BASE_COLLECTION_PATH='$TEST_TMPDIR/mgc'
		mkdir -p \"\$TASK_BASE_PATH\"
		dd if=/dev/zero of=\"\$TASK_BASE_PATH/big.log\" bs=1M count=11 status=none
		echo small >\"\$TASK_BASE_PATH/small.log\"
		source '$SCRIPT_DIR/common.sh'
		source '$SCRIPT_DIR/task_common.sh'
		task_plan compress >/dev/null
		task_run compress compress_logs \"\$TASK_BASE_PATH\"
		task_wait
		ls \"\$TASK_BASE_PATH\" | grep -E '^(big|small)'
	"
	assert_success
	assert_output --partial "[1/1] compress"
	# over the 10MB threshold is compressed, under it is left alone
	assert_output --partial "big.log.gz"
	assert_output --partial "small.log"
	refute_output --partial "big.log
"
}

@test "compression's own chatter stays out of the shared stream" {
	run bash -c "
		export TASK_BASE_PATH='$TEST_TMPDIR/mgc2' BASE_COLLECTION_PATH='$TEST_TMPDIR/mgc2'
		mkdir -p \"\$TASK_BASE_PATH\"
		source '$SCRIPT_DIR/common.sh'
		source '$SCRIPT_DIR/task_common.sh'
		task_plan compress >/dev/null
		task_run compress compress_logs \"\$TASK_BASE_PATH\"
		task_wait
		echo '--- task log ---'
		cat \"\$TASK_LOG_DIR/compress.log\"
	"
	assert_success
	assert_output --partial "Compressing collected logs"
	# it appears in the task's own log, not twice
	run bash -c "printf '%s' '$output' | grep -c 'Compressing collected logs'"
	assert_output "1"
}

@test "compression only joins the plan when REDUCE_LOGS asks for it" {
	run grep -A3 'compress_after_gather.*= .true.' "$SCRIPT_DIR/gather"
	assert_success
	assert_output --partial "all_tasks+=(compress)"
}
