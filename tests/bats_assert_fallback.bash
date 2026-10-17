#!/bin/bash
# Minimal stand-ins for bats-support / bats-assert.
#
# Upstream's test_helper.bash loads those two libraries from tmp/bin, where
# hack/tools.sh puts them after downloading them from GitHub releases. That is
# not possible in an environment restricted to already-configured package
# repositories, and neither library is packaged by Fedora or RHEL.
#
# bats itself *is* packaged, so the only thing missing is a handful of
# assertions. These implement the four the test suite actually uses, with the
# same signatures and the same failure output, so tests do not need changing
# and the real libraries can be dropped in whenever they are available.
#
# Loaded by test_helper.bash only when the real libraries are absent.
#
# shellcheck disable=SC2154  # $status and $output are set by bats' `run`

# assert_success
#   Fail unless the last `run` exited 0.
assert_success() {
	if [ "${status}" -ne 0 ]; then
		{
			echo "-- command failed --"
			echo "status : ${status}"
			echo "output : ${output}"
			echo "--"
		} >&2
		return 1
	fi
}

# assert_failure [status]
#   Fail if the last `run` exited 0, or did not exit with the given status.
assert_failure() {
	if [ "${status}" -eq 0 ]; then
		{
			echo "-- command succeeded, but it was expected to fail --"
			echo "output : ${output}"
			echo "--"
		} >&2
		return 1
	fi
	if [ "$#" -gt 0 ] && [ "${status}" -ne "$1" ]; then
		{
			echo "-- command failed with the wrong status --"
			echo "expected : $1"
			echo "actual   : ${status}"
			echo "--"
		} >&2
		return 1
	fi
}

# assert_output [--partial] <expected>
#   With --partial, require the output to contain <expected>; otherwise
#   require it to equal <expected> exactly.
assert_output() {
	local partial=0
	if [ "${1:-}" = "--partial" ]; then
		partial=1
		shift
	fi
	local expected="${1:-}"

	if [ "${partial}" -eq 1 ]; then
		if [[ "${output}" == *"${expected}"* ]]; then
			return 0
		fi
		{
			echo "-- output does not contain substring --"
			echo "substring : ${expected}"
			echo "output    : ${output}"
			echo "--"
		} >&2
		return 1
	fi

	if [ "${output}" = "${expected}" ]; then
		return 0
	fi
	{
		echo "-- output differs --"
		echo "expected : ${expected}"
		echo "actual   : ${output}"
		echo "--"
	} >&2
	return 1
}

# refute_output [--partial] <expected>
#   The inverse of assert_output.
refute_output() {
	local partial=0
	if [ "${1:-}" = "--partial" ]; then
		partial=1
		shift
	fi
	local unexpected="${1:-}"

	if [ "${partial}" -eq 1 ]; then
		if [[ "${output}" != *"${unexpected}"* ]]; then
			return 0
		fi
		{
			echo "-- output should not contain substring --"
			echo "substring : ${unexpected}"
			echo "output    : ${output}"
			echo "--"
		} >&2
		return 1
	fi

	if [ "${output}" != "${unexpected}" ]; then
		return 0
	fi
	{
		echo "-- output should have differed --"
		echo "output : ${output}"
		echo "--"
	} >&2
	return 1
}
