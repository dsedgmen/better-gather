all: images
.PHONY: all

# Include the library makefile
include $(addprefix ./vendor/github.com/openshift/build-machinery-go/make/, \
	golang.mk \
	targets/openshift/images.mk \
)

IMAGE_REGISTRY :=registry.ci.openshift.org

# Check which builder to use - default is imagebuilder
ifeq ($(BUILDER), podman)
# Use podman to build the must gather image
# Please ensure you have podman installed on your machine for this
IMAGE_BUILD_BUILDER := podman build
# Clear all build default flags
IMAGE_BUILD_DEFAULT_FLAGS :=
# Set authfile if the user passes another location for the authentication file
ifneq ($(strip $(AUTH_FILE)),)
IMAGE_BUILD_DEFAULT_FLAGS := --authfile=$(AUTH_FILE)
endif
endif


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
# BG_BASE has no default on purpose. This image adds only shell scripts,
# so all of its CVE exposure comes from whatever it is layered on, and the
# public must-gather images have not been rebuilt in months. Pass the image
# your cluster runs, or build a current one with image-base.
BG_BASE ?=
BG_BASE_IMAGE ?= better-gather-base:4.19
BG_MAX_BASE_AGE_DAYS ?= 60
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

.PHONY: image-base
image-base:
	podman build -t $(BG_BASE_IMAGE) -f Dockerfile.base .

.PHONY: check-base
check-base:
	@test -n "$(BG_BASE)" || { echo "set BG_BASE, e.g. BG_BASE=\$$(oc adm release info --image-for=must-gather --insecure) for a 4.19 cluster"; exit 2; }
	./hack/check-base.sh --max-age $(BG_MAX_BASE_AGE_DAYS) $(BG_BASE)

.PHONY: image-overlay
image-overlay:
	@test -n "$(BG_BASE)" || { echo "set BG_BASE, e.g. BG_BASE=\$$(oc adm release info --image-for=must-gather --insecure) for a 4.19 cluster"; exit 2; }
	podman build --build-arg BASE=$(BG_BASE) \
		--build-arg BASE_BUILT="$$(./hack/check-base.sh --warn-only $(BG_BASE) 2>/dev/null | sed -n 's/^built: \([0-9-]*\).*/\1/p' | grep . || echo unknown)" \
		-t $(BG_IMAGE) -f Dockerfile.overlay .
