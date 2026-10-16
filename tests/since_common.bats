#!/usr/bin/env bats
# Tests for collection-scripts/since_common.sh and the duration helpers in
# collection-scripts/common.sh.
#
# These cover the behaviour that makes --since mean something for file-based
# collection: oc drops the since parameter for any --path request, so the
# window has to be applied by the collection scripts themselves.

load test_helper

# =============================================================================
# duration_to_seconds()
# =============================================================================

@test "duration_to_seconds sums every component of a Go duration" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		duration_to_seconds '2h30m0s'
	"
	assert_success
	assert_output "9000"
}

@test "duration_to_seconds handles single components" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		echo \"\$(duration_to_seconds '30m0s') \$(duration_to_seconds '45s') \$(duration_to_seconds '1h0m0s') \$(duration_to_seconds '2d0h0m0s')\"
	"
	assert_success
	assert_output "1800 45 3600 172800"
}

@test "duration_to_seconds does not mistake the m of ms for minutes" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		duration_to_seconds '500ms'
	"
	assert_success
	assert_output "0"
}

@test "duration_to_seconds truncates fractional units" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		duration_to_seconds '1.5s'
	"
	assert_success
	assert_output "1"
}

@test "duration_to_seconds returns 0 for junk" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		echo \"[\$(duration_to_seconds 'soon')][\$(duration_to_seconds '')]\"
	"
	assert_success
	assert_output "[0][0]"
}

# =============================================================================
# duration_to_node_logs_since()
# =============================================================================

@test "duration_to_node_logs_since collapses durations without losing time" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		for d in 30m0s 2h30m0s 1h0m0s 90m0s 36h0m0s 45s 168h0m0s 1h0m30s; do
			printf '%s=%s ' \"\$d\" \"\$(duration_to_node_logs_since \"\$d\")\"
		done
	"
	assert_success
	# Every result is exactly equal to the input, never rounded either way.
	assert_output --partial "30m0s=30m"
	assert_output --partial "2h30m0s=150m"
	assert_output --partial "1h0m0s=1h"
	assert_output --partial "90m0s=90m"
	assert_output --partial "36h0m0s=36h"
	assert_output --partial "45s=45s"
	assert_output --partial "168h0m0s=7d"
	assert_output --partial "1h0m30s=3630s"
}

@test "duration_to_node_logs_since round-trips to the same number of seconds" {
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		for d in 30m0s 2h30m0s 90m0s 36h0m0s 1h0m30s 168h0m0s; do
			a=\$(duration_to_seconds \"\$d\")
			b=\$(duration_to_seconds \"\$(duration_to_node_logs_since \"\$d\")\")
			[ \"\$a\" = \"\$b\" ] || { echo \"MISMATCH \$d: \$a != \$b\"; exit 1; }
		done
		echo all-exact
	"
	assert_success
	assert_output "all-exact"
}

@test "duration_to_node_logs_since converts a sub-second window to 1s" {
	# node-logs has no unit finer than the second. Passing '500ms' through
	# would be read as 500 minutes.
	run bash -c "
		source \"$SCRIPT_DIR/common.sh\"
		duration_to_node_logs_since '500ms'
	"
	assert_success
	assert_output "1s"
}

# =============================================================================
# get_since_cutoff()
# =============================================================================

@test "get_since_cutoff resolves MUST_GATHER_SINCE to an absolute instant" {
	run bash -c "
		export MUST_GATHER_SINCE='1h0m0s'
		source \"$SCRIPT_DIR/common.sh\"
		get_since_cutoff
		now=\$(date -u +%s)
		delta=\$((now - since_cutoff_epoch))
		# allow a couple of seconds of slack for slow machines
		[ \"\$delta\" -ge 3598 ] && [ \"\$delta\" -le 3602 ] && echo in-range || echo \"out-of-range: \$delta\"
	"
	assert_success
	assert_output "in-range"
}

@test "get_since_cutoff resolves MUST_GATHER_SINCE_TIME exactly" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T09:00:00Z'
		source \"$SCRIPT_DIR/common.sh\"
		get_since_cutoff
		echo \"\$since_cutoff_rfc3339\"
	"
	assert_success
	assert_output "2026-10-16T09:00:00Z"
}

@test "get_since_cutoff prefers MUST_GATHER_SINCE_TIME over MUST_GATHER_SINCE" {
	run bash -c "
		export MUST_GATHER_SINCE='8h'
		export MUST_GATHER_SINCE_TIME='2026-10-16T09:00:00Z'
		source \"$SCRIPT_DIR/common.sh\"
		get_since_cutoff
		echo \"\$since_cutoff_rfc3339\"
	"
	assert_success
	assert_output "2026-10-16T09:00:00Z"
}

@test "get_since_cutoff leaves the cutoff empty when no window was requested" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		source \"$SCRIPT_DIR/common.sh\"
		get_since_cutoff
		echo \"[\$since_cutoff_epoch][\$since_cutoff_rfc3339]\"
	"
	assert_success
	assert_output "[][]"
}

# =============================================================================
# since_find_predicate()
# =============================================================================

@test "since_find_predicate is empty without a window" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		echo \"[\$(since_find_predicate)]\"
	"
	assert_success
	assert_output "[]"
}

@test "since_find_predicate emits a newermt predicate with a window" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T09:00:00Z'
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		since_find_predicate
	"
	assert_success
	assert_output "-newermt @1792141200"
}

# =============================================================================
# filename_timestamp_epoch()
# =============================================================================

@test "filename_timestamp_epoch reads the audit log naming scheme" {
	run bash -c "
		source \"$SCRIPT_DIR/since_common.sh\"
		filename_timestamp_epoch 'audit-2026-10-16T00-15-40.612.log'
	"
	assert_success
	assert_output "1792109740"
}

@test "filename_timestamp_epoch reads the insights archive naming scheme" {
	run bash -c "
		source \"$SCRIPT_DIR/since_common.sh\"
		filename_timestamp_epoch 'insights-2026-10-16-181710.tar.gz'
	"
	assert_success
	assert_output "1792174630"
}

@test "filename_timestamp_epoch is silent for names without a timestamp" {
	run bash -c "
		source \"$SCRIPT_DIR/since_common.sh\"
		for n in audit.log termination.log .lock .terminating startup.log; do
			printf '[%s]' \"\$(filename_timestamp_epoch \"\$n\")\"
		done
	"
	assert_success
	assert_output "[][][][][]"
}

# =============================================================================
# filter_names_since()
# =============================================================================

@test "filter_names_since passes everything through without a window" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' 'audit-2020-01-01T00-00-00.000.log' 'audit.log' | filter_names_since test
	"
	assert_success
	assert_output "audit-2020-01-01T00-00-00.000.log
audit.log"
}

@test "filter_names_since drops rotated files that end before the cutoff" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' \
			'audit-2026-10-16T18-00-00.000.log' \
			'audit-2026-10-16T06-00-00.000.log' | filter_names_since test
	"
	assert_success
	assert_output "audit-2026-10-16T18-00-00.000.log"
}

@test "filter_names_since always keeps entries with no timestamp in the name" {
	# audit.log is the live file and termination.log has no rotation stamp;
	# these are the most likely to hold recent events, so they must survive.
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' 'audit.log' 'termination.log' '.lock' '.terminating' \
			'audit-2026-10-16T06-00-00.000.log' | filter_names_since test
	"
	assert_success
	assert_output "audit.log
termination.log
.lock
.terminating"
}

@test "filter_names_since handles listings prefixed with a node name" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' \
			'master-0 audit-2026-10-16T18-00-00.000.log' \
			'master-1 audit-2026-10-16T06-00-00.000.log' | filter_names_since test
	"
	assert_success
	assert_output "master-0 audit-2026-10-16T18-00-00.000.log"
}

@test "filter_names_since records what it kept and skipped" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' 'audit.log' \
			'audit-2026-10-16T18-00-00.000.log' \
			'audit-2026-10-16T06-00-00.000.log' \
			'audit-2026-10-15T06-00-00.000.log' | filter_names_since audit_logs/kube-apiserver >/dev/null
		cat \"$TEST_TMPDIR/report.txt\"
	"
	assert_success
	assert_output --partial "audit_logs/kube-apiserver"
	assert_output --partial "kept=2"
	assert_output --partial "skipped=2"
}

# =============================================================================
# trim_jsonl_since()
# =============================================================================

@test "trim_jsonl_since passes everything through without a window" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' '{\"requestReceivedTimestamp\":\"2020-01-01T00:00:00Z\"}' | trim_jsonl_since
	"
	assert_success
	assert_output '{"requestReceivedTimestamp":"2020-01-01T00:00:00Z"}'
}

@test "trim_jsonl_since drops audit events older than the cutoff" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' \
			'{\"auditID\":\"new\",\"requestReceivedTimestamp\":\"2026-10-16T18:00:00.1Z\"}' \
			'{\"auditID\":\"old\",\"requestReceivedTimestamp\":\"2026-10-16T06:00:00.1Z\"}' | trim_jsonl_since
	"
	assert_success
	assert_output --partial '"auditID":"new"'
	refute_output --partial '"auditID":"old"'
}

@test "trim_jsonl_since passes non-JSON lines through verbatim" {
	# /var/log/etcd holds plain text, not audit events. Silently emptying it
	# would be far worse than collecting too much.
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' \
			'2026-10-16 06:00:00 I | etcdserver: plain text line' \
			'another plain line' | trim_jsonl_since
	"
	assert_success
	assert_output "2026-10-16 06:00:00 I | etcdserver: plain text line
another plain line"
}

@test "trim_jsonl_since keeps JSON objects that lack the timestamp field" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		printf '%s\n' '{\"auditID\":\"nofield\"}' | trim_jsonl_since
	"
	assert_success
	assert_output '{"auditID":"nofield"}'
}

# =============================================================================
# since_report()
# =============================================================================

@test "since_report_header names the window in force" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T09:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		since_report_header
		cat \"$TEST_TMPDIR/report.txt\"
	"
	assert_success
	assert_output --partial "better-gather --since report"
	assert_output --partial "2026-10-16T09:00:00Z"
}

@test "since_report_header says so when no window was requested" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		since_report_header
		cat \"$TEST_TMPDIR/report.txt\"
	"
	assert_success
	assert_output --partial "none requested"
}

@test "since_report_header is written only once" {
	run bash -c "
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		since_report_header
		since_report_header
		grep -c 'better-gather --since report' \"$TEST_TMPDIR/report.txt\"
	"
	assert_success
	assert_output "1"
}

# =============================================================================
# Sourcing is side-effect free
# =============================================================================

@test "sourcing since_common.sh changes nothing when no window is requested" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		since_window_requested && echo 'window' || echo 'no-window'
		echo \"predicate=[\$(since_find_predicate)]\"
	"
	assert_success
	assert_output --partial "no-window"
	assert_output --partial "predicate=[]"
}

# =============================================================================
# copy_pod_dir_since() / pod_tar_dirs_since() layout
# =============================================================================
#
# These exercise the path arithmetic only, with a stub oc. Getting it wrong
# silently reshapes the archive: tarring an absolute path lands everything
# under <dest>/a/b/... instead of where oc cp or rsync would have put it.

@test "copy_pod_dir_since tars the directory itself without a trailing slash" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		mkdir -p \"$TEST_TMPDIR/mocks\"
		printf '#!/bin/bash\necho \"\$*\" >>\"$TEST_TMPDIR/cmds\"\nexit 0\n' > \"$TEST_TMPDIR/mocks/oc\"
		chmod +x \"$TEST_TMPDIR/mocks/oc\"
		export PATH=\"$TEST_TMPDIR/mocks:\$PATH\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		copy_pod_dir_since ns pod '' /a/b \"$TEST_TMPDIR/dest\" lbl >/dev/null 2>&1
		grep -o \"cd '[^']*' .*find '[^']*'\" \"$TEST_TMPDIR/cmds\" | tail -1
	"
	assert_success
	assert_output --partial "cd '/a'"
	assert_output --partial "find 'b'"
}

@test "copy_pod_dir_since tars the contents with a trailing slash" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		mkdir -p \"$TEST_TMPDIR/mocks\"
		printf '#!/bin/bash\necho \"\$*\" >>\"$TEST_TMPDIR/cmds\"\nexit 0\n' > \"$TEST_TMPDIR/mocks/oc\"
		chmod +x \"$TEST_TMPDIR/mocks/oc\"
		export PATH=\"$TEST_TMPDIR/mocks:\$PATH\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		copy_pod_dir_since ns pod '' /a/b/ \"$TEST_TMPDIR/dest\" lbl >/dev/null 2>&1
		grep -o \"cd '[^']*' .*find '[^']*'\" \"$TEST_TMPDIR/cmds\" | tail -1
	"
	assert_success
	assert_output --partial "cd '/a/b'"
	assert_output --partial "find '.'"
}

@test "copy_pod_dir_since falls back to oc cp without a window" {
	run bash -c "
		unset MUST_GATHER_SINCE MUST_GATHER_SINCE_TIME
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		mkdir -p \"$TEST_TMPDIR/mocks\"
		printf '#!/bin/bash\necho \"\$*\" >>\"$TEST_TMPDIR/cmds\"\nexit 0\n' > \"$TEST_TMPDIR/mocks/oc\"
		chmod +x \"$TEST_TMPDIR/mocks/oc\"
		export PATH=\"$TEST_TMPDIR/mocks:\$PATH\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		copy_pod_dir_since ns pod '' /a/b/ \"$TEST_TMPDIR/dest\" lbl >/dev/null 2>&1
		cat \"$TEST_TMPDIR/cmds\"
	"
	assert_success
	# unchanged upstream behaviour, and the trailing slash is dropped for oc cp
	assert_output --partial "cp -n ns pod:/a/b"
	refute_output --partial "find"
}

@test "pod_tar_dirs_since makes several absolute paths relative to /" {
	run bash -c "
		export MUST_GATHER_SINCE_TIME='2026-10-16T12:00:00Z'
		export SINCE_REPORT_PATH=\"$TEST_TMPDIR/report.txt\"
		mkdir -p \"$TEST_TMPDIR/mocks\"
		printf '#!/bin/bash\necho \"\$*\" >>\"$TEST_TMPDIR/cmds\"\nexit 0\n' > \"$TEST_TMPDIR/mocks/oc\"
		chmod +x \"$TEST_TMPDIR/mocks/oc\"
		export PATH=\"$TEST_TMPDIR/mocks:\$PATH\"
		source \"$SCRIPT_DIR/since_common.sh\"
		get_since_cutoff
		pod_tar_dirs_since ns pod compute \"$TEST_TMPDIR/dest\" lbl \
			/var/log/libvirt/qemu/ /var/run/libvirt/qemu/log/ >/dev/null 2>&1
		cat \"$TEST_TMPDIR/cmds\"
	"
	assert_success
	assert_output --partial "cd / && find 'var/log/libvirt/qemu/' 'var/run/libvirt/qemu/log/'"
	assert_output --partial "-newermt @"
}
