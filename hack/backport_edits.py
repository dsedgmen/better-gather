#!/usr/bin/env python3
"""Re-apply the --since edits to upstream's own collection scripts.

Called by hack/backport.sh once a release branch has been checked out and the
files that are wholly ours have been copied in. Everything here edits a file
that upstream owns, so each edit is matched against the text as it exists on
*that* branch and reports whether it applied.

An edit that does not match is not silently skipped: scripts change between
releases, and a backport that quietly dropped the filter would look fine and
collect everything. Required edits that fail to match make the run fail.
"""

from __future__ import annotations

import pathlib
import re
import sys

results: list[tuple[str, str, bool]] = []


def edit(path, old, new, *, required=True, label=None):
    """Apply one replacement, recording whether it matched."""
    p = pathlib.Path(path)
    name = label or path.split("/")[-1]
    if not p.exists():
        results.append((name, "file absent", not required))
        return False
    text = p.read_text()
    if new in text:
        results.append((name, "already applied", True))
        return True
    if old not in text:
        results.append((name, "NO MATCH", not required))
        return False
    p.write_text(text.replace(old, new, 1))
    results.append((name, "applied", True))
    return True


def edit_re(path, pattern, repl, *, required=True, label=None, flags=0):
    p = pathlib.Path(path)
    name = label or path.split("/")[-1]
    if not p.exists():
        results.append((name, "file absent", not required))
        return False
    text = p.read_text()
    new_text, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n == 0:
        results.append((name, "NO MATCH", not required))
        return False
    p.write_text(new_text)
    results.append((name, "applied", True))
    return True


CS = "collection-scripts"

# --------------------------------------------------------------------------
# common.sh: source the library, and collapse durations exactly
# --------------------------------------------------------------------------

edit(f"{CS}/common.sh",
     "#!/bin/bash\n",
     "#!/bin/bash\n\n"
     "# duration_to_node_logs_since and get_since_cutoff live in\n"
     "# since_common.sh so the library is self-contained and can be vendored\n"
     "# into the CNV and ODF forks. The dependency runs one way only.\n"
     "# shellcheck source=collection-scripts/since_common.sh\n"
     'source "$(dirname "${BASH_SOURCE[0]}")/since_common.sh"\n',
     label="common.sh: source library")

# Upstream writes this with varying indentation and comments across branches,
# so match the sed itself rather than its surroundings.
edit_re(f"{CS}/common.sh",
        r'(?P<indent>[ \t]*)since=\$\(echo "\$\{MUST_GATHER_SINCE:-\}" \| sed [^\n]*\)\n',
        lambda m: (
            f"{m.group('indent')}# node-logs takes a single "
            "'(+|-)[0-9]+(s|m|h|d)' component, so a multi-component\n"
            f"{m.group('indent')}# duration has to be collapsed into one. Keeping only the "
            "first\n"
            f"{m.group('indent')}# component, as this did, silently narrows the window: 2h30m\n"
            f"{m.group('indent')}# becomes -2h and 500ms becomes -500m, read as 500 minutes.\n"
            f'{m.group("indent")}since=$(duration_to_node_logs_since "${{MUST_GATHER_SINCE}}")\n'
        ),
        label="common.sh: exact duration")

# --------------------------------------------------------------------------
# gather_audit_logs: filter the listing, trim what is downloaded
# --------------------------------------------------------------------------

edit_re(f"{CS}/gather_audit_logs",
        r'(source "\$\(dirname "\$0"\)/common\.sh"\n[ \t]*get_log_collection_args\n)',
        r'''\1
# oc drops --since for a --path request and the kubelet does not time-filter
# file serving, so the arguments threaded through below have no effect on
# their own. Apply the window here instead.
# shellcheck source=collection-scripts/since_common.sh
SINCE_COMMON="$(dirname "$0")/since_common.sh"
source "${SINCE_COMMON}"
export SINCE_COMMON
get_since_cutoff
since_report_header
''',
        label="audit_logs: preamble")

# The listing pipeline is written with a trailing pipe on main and with
# "| \\" continuations on older branches.
if not edit_re(f"{CS}/gather_audit_logs",
               r'(\n[ \t]*grep -v "\.lock" \|\n)',
               r'\1\t\tfilter_names_since "audit_logs/$path" |\n',
               required=False, label="audit_logs: listing filter"):
    edit_re(f"{CS}/gather_audit_logs",
            r'(\n[ \t]*grep -v "\.lock" \| \\\n)',
            r'\1  filter_names_since "audit_logs/$path" | \\\n',
            label="audit_logs: listing filter (continuation style)")

edit_re(f"{CS}/gather_audit_logs",
        r'oc adm node-logs \$\{5:\+"\$5"\}([^\n]*)--path=\$1/\$4 \| gzip',
        r'source "${SINCE_COMMON}"; oc adm node-logs ${5:+"$5"}\1--path=$1/$4 | trim_jsonl_since | gzip',
        label="audit_logs: content trim")

# --------------------------------------------------------------------------
# gather_network_logs: bound the libovsdb tarball
# --------------------------------------------------------------------------

edit_re(f"{CS}/gather_network_logs",
        r'(BASE_COLLECTION_PATH="must-gather"\n)',
        r'''# shellcheck source=collection-scripts/since_common.sh
source "$(dirname "$0")/since_common.sh"
get_since_cutoff
since_report_header

\1''',
        required=False, label="network_logs: preamble")

edit_re(f"{CS}/gather_network_logs",
        r"""bash -c 'find /var/log/ovnkube -type f -name "libovsdb\*log\*" \| tar czf - -T -'""",
        r'''bash -c "find /var/log/ovnkube -type f -name 'libovsdb*log*' $(since_find_predicate) | tar czf - -T -"''',
        required=False, label="network_logs: find predicate")

# --------------------------------------------------------------------------
# gather_insights: bound the archive copy
# --------------------------------------------------------------------------

edit_re(f"{CS}/gather_insights",
        r'(\n)(# shellcheck disable=SC2086\n)?(oc \$COLLECTOR --namespace=openshift-insights [^\n]*\n)',
        r'''\1# shellcheck source=collection-scripts/since_common.sh
source "$(dirname "$0")/since_common.sh"
get_since_cutoff
since_report_header

if since_window_requested; then
\t# Archives are named insights-<timestamp>.tar.gz and written once, so
\t# mtime is creation time. This is the "prune or limit" the TODO below
\t# asks for, scoped to the window already requested.
\techo "INFO: limiting archives to those written since ${since_cutoff_rfc3339}"
\tcopy_pod_dir_since openshift-insights "$INSIGHTS_OPERATOR_POD" "" \\
\t\t/var/lib/insights-operator "$INSIGHTS_DATA_PATH" insights
else
\t\2\3fi
''',
        required=False, label="insights: bounded copy")

# --------------------------------------------------------------------------
# Makefile: shell lint and tests, self-contained
# --------------------------------------------------------------------------
#
# Upstream's Makefile differs across release branches -- the older ones have
# no bats wiring at all -- so append a block that defines everything it needs
# under a BG_ prefix rather than relying on upstream's variables.

MAKEFILE_BLOCK = """
# --- better-gather: shell lint and tests -----------------------------------
# Self-contained and BG_-prefixed so it cannot collide with upstream's
# variables, which differ between release branches. bats-check rather than
# `test`: on branches that vendor build-machinery-go, `test` has test-unit
# attached to it and hard-requires a Go toolchain.
BG_LOCALBIN ?= $(shell pwd)/tmp/bin
BG_BATS ?= $(BG_LOCALBIN)/bats
BG_SHELLCHECK ?= $(BG_LOCALBIN)/shellcheck
BG_SCRIPT_DIRS := collection-scripts/ hack/ tests/
BG_BASE ?= quay.io/openshift/origin-must-gather:latest
BG_IMAGE ?= better-gather:latest

$(BG_LOCALBIN)/%:
\t./hack/tools-from-packages.sh $*

.PHONY: bats-lint
bats-lint: $(BG_SHELLCHECK)
\tfind $(BG_SCRIPT_DIRS) -type f -not -path '*/vendor/*' \\
\t\t-exec grep -Eq '^#!/' {} \\; -exec $(BG_SHELLCHECK) -x {} +

.PHONY: bats-test
bats-test: $(BG_BATS)
\t$(BG_BATS) tests/*.bats

.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-overlay
image-overlay:
\tpodman build --build-arg BASE=$(BG_BASE) -t $(BG_IMAGE) -f Dockerfile.overlay .
"""

mk = pathlib.Path("Makefile")
if mk.exists():
    mk_text = mk.read_text()
    if "bats-check" in mk_text:
        results.append(("Makefile: bats targets", "already applied", True))
    else:
        mk.write_text(mk_text.rstrip("\n") + "\n" + MAKEFILE_BLOCK)
        results.append(("Makefile: bats targets", "applied", True))
else:
    results.append(("Makefile: bats targets", "no Makefile", False))

summary_failed = [r for r in results if not r[2]]

width = max((len(r[0]) for r in results), default=10)
for name, status, ok in results:
    mark = "ok " if ok else "FAIL"
    print(f"  [{mark}] {name:<{width}}  {status}")

if summary_failed:
    print(f"\n{len(summary_failed)} required edit(s) did not apply; "
          "the branch would silently collect everything.", file=sys.stderr)
    sys.exit(1)
