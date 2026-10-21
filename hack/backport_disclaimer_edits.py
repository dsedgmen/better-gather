#!/usr/bin/env python3
"""Rewrite a release branch's README, Makefile, gather and CI for the
disclaimer and the security scans.

Called by hack/backport-disclaimer.sh, which has already dropped DISCLAIMER,
.trivyignore, tests/disclaimer.bats, Dockerfile.overlay and
hack/tools-from-packages.sh into place.

Anchors are deliberately loose where the release branches are known to differ
from main -- `gather`'s preamble spacing, and a README that is still purely
upstream's. Everything else asserts an exact match and stops the backport
rather than committing a half-edit.
"""

from __future__ import annotations

import pathlib
import re
import sys

import yaml


def replace(text, old, new, what, count=-1):
    if old not in text:
        raise SystemExit(f"backport_disclaimer_edits: {what}: pattern not found")
    return text.replace(old, new) if count < 0 else text.replace(old, new, count)


BANNER = """\
better-gather ({branch})
{underline}

A fork of [openshift/must-gather](https://github.com/openshift/must-gather) in
which `--since` actually bounds what is collected, branched for OpenShift
{version}.

> ### ⚠️ Not a Red Hat product
>
> This is a personal, unofficial fork. It is **not built, reviewed, supported
> or endorsed by Red Hat**, and it is provided **without warranty or support
> of any kind** — use it, and anything it collects, at your own risk. See
> [`LICENSE`](LICENSE) and [`DISCLAIMER`](DISCLAIMER), a copy of which ships
> in the image and is written into every collection it produces.
>
> Because `--since` really does bound collection here, an archive from this
> tool may hold less than a stock must-gather would. If you attach one to a
> Red Hat support case, say that it came from an unofficial tool; support may
> ask for a collection from the supported must-gather image instead.

Upstream's README follows below, unchanged.

"""


def patch_readme(version):
    p = pathlib.Path("README.md")
    s = p.read_text()
    if "Not a Red Hat product" in s:
        return  # already done; makes the script safe to re-run
    branch = f"release-{version}"
    head = BANNER.format(
        branch=branch,
        underline="=" * len(f"better-gather ({branch})"),
        version=version,
    )
    p.write_text(head + s)


def patch_gather():
    p = pathlib.Path("collection-scripts/gather")
    s = p.read_text()
    if "better-gather/DISCLAIMER" in s:
        return

    # The release branches and main disagree about whitespace around the
    # redirect, so match the line rather than quoting it.
    m = re.search(r"^version\s*>>\s*/must-gather/version\s*$", s, re.M)
    if not m:
        raise SystemExit("backport_disclaimer_edits: gather: version line not found")

    block = """

# Say whose tool this is, in the run output and in the archive. Whoever ends
# up reading the collection is rarely whoever ran it, and nothing else in a
# must-gather tarball would tell them it did not come from the supported
# image. Not fatal if the file is missing: someone may have assembled an
# image without it.
if [ -r /usr/share/better-gather/DISCLAIMER ]; then
\tcat /usr/share/better-gather/DISCLAIMER >&2
\tcp /usr/share/better-gather/DISCLAIMER /must-gather/DISCLAIMER
else
\techo "WARNING: better-gather is not a Red Hat product and is unsupported." >&2
fi"""
    p.write_text(s[: m.end()] + block + s[m.end() :])


SCAN_TARGETS = """
# Security scanning. Reporting only -- nothing here fails a build, by
# design: an unfixed CVE in the base is not something this repo can action,
# and a gate that cannot be satisfied just gets ignored. CI runs the same two
# scans and keeps the reports as artifacts.
#
#   hack/tools-from-packages.sh trivy     # not in the default tool set
#
# vendor/ is skipped: it is third-party code this repo does not build, and it
# carries Kubernetes test fixtures that trip every pod-security rule. Module
# vulnerabilities are still found, because those come from go.mod rather than
# from the vendored sources.
BG_SCAN_SEVERITY ?= HIGH,CRITICAL

.PHONY: scan-code
scan-code:
\t@test -x "$(BG_TRIVY)" || { echo "run: ./hack/tools-from-packages.sh trivy"; exit 2; }
\t$(BG_TRIVY) filesystem --scanners vuln,secret,misconfig \\
\t\t--skip-dirs '**/vendor' \\
\t\t--severity $(BG_SCAN_SEVERITY) --exit-code 0 .

# Via a saved archive rather than the image store: rootless podman has no
# socket for trivy to talk to unless podman.socket happens to be running, and
# --input works the same everywhere.
.PHONY: scan-image
scan-image:
\t@test -x "$(BG_TRIVY)" || { echo "run: ./hack/tools-from-packages.sh trivy"; exit 2; }
\t@set -e; \\
\ttmpdir="$$(mktemp -d)"; \\
\ttrap 'rm -rf "$$tmpdir"' EXIT; \\
\tpodman save --format docker-archive -o "$$tmpdir/image.tar" $(BG_IMAGE); \\
\t$(BG_TRIVY) image --input "$$tmpdir/image.tar" --scanners vuln \\
\t\t--severity $(BG_SCAN_SEVERITY) --exit-code 0

.PHONY: scan
scan: scan-code scan-image

.PHONY: image-base
"""


def patch_makefile():
    p = pathlib.Path("Makefile")
    s = p.read_text()
    if "BG_TRIVY" in s:
        return
    s = replace(
        s,
        "BG_SHELLCHECK ?= $(BG_LOCALBIN)/shellcheck\n",
        "BG_SHELLCHECK ?= $(BG_LOCALBIN)/shellcheck\nBG_TRIVY ?= $(BG_LOCALBIN)/trivy\n",
        "Makefile tool vars",
        1,
    )
    s = replace(s, "\n.PHONY: image-base\n", SCAN_TARGETS, "Makefile image-base", 1)
    p.write_text(s)


SCAN_JOB = """  scan-code:
    # Vulnerable dependencies, committed secrets and Dockerfile
    # misconfiguration. Reporting only: this job never fails the build.
    # Accepted findings live in .trivyignore, each with a reason.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Scan the tree
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: fs
          scan-ref: .
          scanners: vuln,secret,misconfig
          skip-dirs: '**/vendor'
          severity: HIGH,CRITICAL
          format: table
          exit-code: 0

      - name: Keep the code scan as an artifact
        if: always()
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          scan-type: fs
          scan-ref: .
          scanners: vuln,secret,misconfig
          skip-dirs: '**/vendor'
          format: json
          output: trivy-code.json
          exit-code: 0

      - name: Upload the code scan
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: trivy-code-${{ github.sha }}
          path: trivy-code.json
          if-no-files-found: warn

  build:
"""

IMAGE_SCAN = """      - name: Scan the image for vulnerabilities
        # Reporting only: `exit-code: 0`. This image adds no packages of its
        # own, so an unfixed CVE in the base is not something it can action,
        # and a gate nobody can satisfy only teaches people to ignore it. The
        # staleness gate above is the one that does fail.
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ env.IMAGE_NAME }}:ci
          scanners: vuln
          severity: HIGH,CRITICAL
          format: table
          exit-code: 0

      - name: Keep the image scan as an artifact
        if: always()
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ env.IMAGE_NAME }}:ci
          scanners: vuln
          format: json
          output: trivy-image.json
          exit-code: 0

      - name: Upload the image scan
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: trivy-image-${{ github.sha }}
          path: trivy-image.json
          if-no-files-found: warn

      - name: Work out the tags
"""


def patch_workflow():
    p = pathlib.Path(".github/workflows/ci.yml")
    s = p.read_text()
    if "trivy-action" in s:
        return
    s = replace(s, "\n  build:\n", "\n" + SCAN_JOB, "ci.yml build job", 1)
    s = replace(
        s,
        "      - name: Work out the tags\n",
        IMAGE_SCAN,
        "ci.yml tags step",
        1,
    )
    d = yaml.safe_load(s)
    if "scan-code" not in d["jobs"]:
        raise SystemExit("backport_disclaimer_edits: scan-code job did not land")
    p.write_text(s)


def main(argv):
    if len(argv) != 2:
        raise SystemExit("usage: backport_disclaimer_edits.py <version>")
    version = argv[1]
    patch_readme(version)
    patch_gather()
    patch_makefile()
    patch_workflow()
    print(f"    patched README, gather, Makefile and ci.yml for {version}")


if __name__ == "__main__":
    main(sys.argv)
