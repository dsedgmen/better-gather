#!/bin/bash
# Run three trivial tasks and print how many results were recorded.
#
# A fixture rather than an inline snippet because the flock tests need to
# run it under a doctored PATH, and nesting that inside bats' own quoting
# is unreadable and easy to get wrong.
#
#   TASK_BASE_PATH=<dir> tests/fixtures/task_scenario.sh <library path>
set -eu
# shellcheck source=/dev/null
source "$1"
task_plan t1 t2 t3 >/dev/null
task_run t1 true
task_run t2 true
task_run t3 true
task_wait
printf "RECORDED=%s\n" "$(wc -l <"${TASK_RESULTS}" | tr -d "[:space:]")"
