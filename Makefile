all: images
.PHONY: all

# Include the library makefile
include $(addprefix ./vendor/github.com/openshift/build-machinery-go/make/, \
	golang.mk \
	targets/openshift/images.mk \
)

IMAGE_REGISTRY :=registry.ci.openshift.org

# This will call a macro called "build-image" which will generate image specific targets based on the parameters:
# $0 - macro name
# $1 - target name
# $2 - image ref
# $3 - Dockerfile path
# $4 - context directory for image build
$(call build-image,ocp-must-gather,$(IMAGE_REGISTRY)/ocp/4.17:ocp-must-gather, ./Dockerfile.ocp,.)

$(call verify-golang-versions,Dockerfile.ocp)

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
	./hack/tools-from-packages.sh $*

.PHONY: bats-lint
bats-lint: $(BG_SHELLCHECK)
	find $(BG_SCRIPT_DIRS) -type f -not -path '*/vendor/*' \
		-exec grep -Eq '^#!.*/(env +)?(ba|da|k|z)?sh' {} \; -exec $(BG_SHELLCHECK) -x {} +

.PHONY: bats-test
bats-test: $(BG_BATS)
	$(BG_BATS) tests/*.bats

.PHONY: bats-check
bats-check: bats-lint bats-test

.PHONY: image-overlay
image-overlay:
	podman build --build-arg BASE=$(BG_BASE) -t $(BG_IMAGE) -f Dockerfile.overlay .
