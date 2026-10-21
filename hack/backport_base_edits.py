#!/usr/bin/env python3
"""Rewrite a release branch's Makefile and CI workflow for the UBI9 base.

Called by hack/backport-base.sh, which has already dropped Dockerfile.base,
Dockerfile.overlay, hack/check-base.sh and tests/check_base.bats into place.
Kept separate because these are structured edits to indentation-sensitive
YAML, which sed does badly.

Every substitution asserts it matched. A release branch that has drifted
should stop the backport rather than be committed half-edited.
"""

from __future__ import annotations

import pathlib
import sys

import yaml


def replace(text, old, new, what):
    if old not in text:
        raise SystemExit(f"backport_base_edits: {what}: pattern not found")
    return text.replace(old, new)


def patch_makefile(version):
    p = pathlib.Path("Makefile")
    s = p.read_text()

    s = replace(
        s,
        "BG_BASE ?= quay.io/openshift/origin-must-gather:latest\n",
        "# BG_BASE has no default on purpose. This image adds only shell scripts,\n"
        "# so all of its CVE exposure comes from whatever it is layered on, and the\n"
        "# public must-gather images have not been rebuilt in months. Pass the image\n"
        "# your cluster runs, or build a current one with image-base.\n"
        "BG_BASE ?=\n"
        f"BG_BASE_IMAGE ?= better-gather-base:{version}\n"
        "BG_MAX_BASE_AGE_DAYS ?= 60\n",
        "Makefile BG_BASE",
    )

    need_base = (
        "\t@test -n \"$(BG_BASE)\" || "
        "{ echo \"set BG_BASE, e.g. BG_BASE=\\$$(oc adm release info "
        f"--image-for=must-gather --insecure) for a {version} cluster\"; exit 2; }}\n"
    )

    s = replace(
        s,
        ".PHONY: image-overlay\n"
        "image-overlay:\n"
        "\tpodman build --build-arg BASE=$(BG_BASE) -t $(BG_IMAGE) -f Dockerfile.overlay .\n",
        ".PHONY: image-base\n"
        "image-base:\n"
        "\tpodman build -t $(BG_BASE_IMAGE) -f Dockerfile.base .\n"
        "\n"
        ".PHONY: check-base\n"
        "check-base:\n"
        + need_base
        + "\t./hack/check-base.sh --max-age $(BG_MAX_BASE_AGE_DAYS) $(BG_BASE)\n"
        "\n"
        ".PHONY: image-overlay\n"
        "image-overlay:\n"
        + need_base
        + "\tpodman build --build-arg BASE=$(BG_BASE) \\\n"
        "\t\t--build-arg BASE_BUILT=\"$$(./hack/check-base.sh --warn-only $(BG_BASE) "
        "2>/dev/null | sed -n 's/^built: \\([0-9-]*\\).*/\\1/p' | grep . || echo unknown)\" \\\n"
        "\t\t-t $(BG_IMAGE) -f Dockerfile.overlay .\n",
        "Makefile image-overlay",
    )

    p.write_text(s)


def patch_workflow(version):
    p = pathlib.Path(".github/workflows/ci.yml")
    s = p.read_text()

    s = replace(
        s,
        "  PUBLIC_BASE: quay.io/openshift/origin-must-gather:latest\n",
        "  # Built here from UBI9 rather than pulled: no public must-gather image\n"
        "  # has been rebuilt recently enough to ship on.\n"
        "  #\n"
        "  # Via a scratch registry on the runner, not a bare local tag: buildx's\n"
        "  # docker-container driver has its own image store and cannot see what\n"
        "  # `--load` put in the docker daemon, so the overlay's FROM would be\n"
        "  # resolved against Docker Hub and fail.\n"
        f"  BASE_IMAGE: localhost:5000/better-gather-base:{version}\n"
        "  MAX_BASE_AGE_DAYS: \"60\"\n",
        "ci.yml PUBLIC_BASE",
    )

    s = replace(
        s,
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        "\n"
        "      - uses: docker/setup-buildx-action@v3\n",
        "    services:\n"
        "      # Somewhere for the base image to live between the two builds below.\n"
        "      # Thrown away with the runner; nothing is published from here.\n"
        "      registry:\n"
        "        image: registry:2\n"
        "        ports:\n"
        "          - 5000:5000\n"
        "\n"
        "    steps:\n"
        "      - uses: actions/checkout@v4\n"
        "\n"
        "      - uses: docker/setup-buildx-action@v3\n"
        "        with:\n"
        "          # So the builder container can reach the registry service on\n"
        "          # localhost:5000. BuildKit treats localhost registries as plain\n"
        "          # HTTP, so no certificate wrangling is needed.\n"
        "          driver-opts: network=host\n"
        "\n"
        f"      - name: Build a {version} base from UBI9\n"
        "        # No credentials needed, and rebuilt continuously upstream, unlike\n"
        "        # every public must-gather image. oc is pinned to this branch's\n"
        "        # minor so the image ships a matching client.\n"
        "        run: |\n"
        "          docker buildx build \\\n"
        "            --platform \"$PLATFORMS\" \\\n"
        "            -f Dockerfile.base \\\n"
        "            -t \"$BASE_IMAGE\" \\\n"
        "            --push .\n"
        "\n"
        "      - name: Refuse to ship on a stale base\n"
        "        run: |\n"
        "          ./hack/check-base.sh --max-age \"$MAX_BASE_AGE_DAYS\" \\\n"
        "            registry.access.redhat.com/ubi9/ubi-minimal:latest\n",
        "ci.yml steps",
    )

    s = replace(
        s,
        '            --build-arg BASE="$PUBLIC_BASE" \\',
        '            --build-arg BASE="$BASE_IMAGE" \\\n'
        '            --build-arg BASE_BUILT="$(date -u +%Y-%m-%d)" \\',
        "ci.yml build args",
    )

    if "PUBLIC_BASE" in s:
        raise SystemExit("backport_base_edits: PUBLIC_BASE still referenced")

    yaml.safe_load(s)  # refuse to write YAML that does not parse
    p.write_text(s)


def main(argv):
    if len(argv) != 2:
        raise SystemExit("usage: backport_base_edits.py <version>")
    version = argv[1]
    patch_makefile(version)
    patch_workflow(version)
    print(f"    patched Makefile and ci.yml for {version}")


if __name__ == "__main__":
    main(sys.argv)
