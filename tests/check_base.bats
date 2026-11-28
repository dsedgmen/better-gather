#!/usr/bin/env bats
#
# hack/check-base.sh guards against shipping on a stale base image. It runs in
# CI, where a registry may be unreachable and skopeo may not be installed, so
# most of what matters here is that it stays on its feet in those cases rather
# than failing the build for the wrong reason.

load test_helper

setup() {
	CHECK_BASE="${PROJECT_ROOT}/hack/check-base.sh"
	STUB_DIR="$(mktemp -d)"
	export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
	rm -rf "${STUB_DIR}"
}

# Stand in for skopeo, reporting the given build date. An empty date means the
# inspect fails, as it does for an unreachable or credentialed registry.
stub_skopeo() {
	local created="$1"
	cat >"${STUB_DIR}/skopeo" <<-EOF
		#!/bin/bash
		[[ -n "${created}" ]] || exit 1
		echo '{"Created": "${created}T00:00:00Z"}'
	EOF
	chmod +x "${STUB_DIR}/skopeo"
	# So the local-image-store fallbacks never answer in these tests, on a
	# machine that has them or one that does not.
	for stub in podman docker; do
		printf '#!/bin/bash\nexit 1\n' >"${STUB_DIR}/${stub}"
		chmod +x "${STUB_DIR}/${stub}"
	done
}

@test "check-base: a fresh base passes" {
	stub_skopeo "$(date -u -d '3 days ago' +%F)"
	run "${CHECK_BASE}" --max-age 60 example.invalid/base:latest
	[ "$status" -eq 0 ]
	[[ "$output" == *"3 days ago"* ]]
	[[ "$output" == *"within the 60 day limit"* ]]
}

@test "check-base: a stale base fails, and says what to use instead" {
	stub_skopeo "$(date -u -d '200 days ago' +%F)"
	run "${CHECK_BASE}" --max-age 60 example.invalid/base:latest
	[ "$status" -eq 1 ]
	[[ "$output" == *"200 days old"* ]]
	[[ "$output" == *"--image-for=must-gather"* ]]
}

@test "check-base: --warn-only reports a stale base without failing" {
	stub_skopeo "$(date -u -d '200 days ago' +%F)"
	run "${CHECK_BASE}" --warn-only --max-age 60 example.invalid/base:latest
	[ "$status" -eq 0 ]
	[[ "$output" == *"200 days old"* ]]
	[[ "$output" == *"continuing anyway"* ]]
}

# The regression this file was written for. Under `set -e -o pipefail` a failing
# command substitution aborts the assignment, so the script used to exit 1 with
# no output at all rather than reaching the warning below it -- which in CI
# looked exactly like a genuinely stale base.
@test "check-base: an unreachable registry warns, it does not fail the build" {
	stub_skopeo ""
	run "${CHECK_BASE}" --max-age 60 example.invalid/unreachable:latest
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not determine"* ]]
}

# Date-shaped enough to get past the regex, but not a date.
@test "check-base: an unparseable build date warns, it does not fail the build" {
	stub_skopeo "2026-13-45"
	run "${CHECK_BASE}" --max-age 60 example.invalid/base:latest
	[ "$status" -eq 0 ]
	[[ "$output" == *"unparseable"* ]]
}

@test "check-base: neither skopeo nor podman installed is a warning" {
	# A PATH carrying only what the script itself needs, so that `command -v`
	# finds neither inspector.
	local bare="${STUB_DIR}/bare"
	mkdir -p "${bare}"
	for tool in date sed cut head; do
		ln -s "$(command -v "${tool}")" "${bare}/${tool}"
	done
	run env PATH="${bare}" "${BASH}" "${CHECK_BASE}" --max-age 60 example.invalid/base:latest
	[ "$status" -eq 0 ]
	[[ "$output" == *"could not determine"* ]]
}

@test "check-base: no image argument is a usage error" {
	run "${CHECK_BASE}" --max-age 60
	[ "$status" -eq 2 ]
	[[ "$output" == *"usage:"* ]]
}
