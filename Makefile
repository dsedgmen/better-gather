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
# ART_DNF_WRAPPER_POLICY=skip: skip the ART image-build DNF wrapper so local podman
# builds use ordinary dnf; the wrapper applies in CI/product pipelines, not here.
IMAGE_BUILD_DEFAULT_FLAGS := --env ART_DNF_WRAPPER_POLICY=skip
# Set authfile if the user passes another location for the authentication file
ifneq ($(strip $(AUTH_FILE)),)
IMAGE_BUILD_DEFAULT_FLAGS += --authfile=$(AUTH_FILE)
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

# Overlay build: layer the collection scripts onto an existing must-gather
# image, so the base is version-matched to the cluster under test and needs no
# CI credentials. See Dockerfile.overlay.
BASE ?= quay.io/openshift/origin-must-gather:latest
OVERLAY_IMAGE ?= better-gather:latest

.PHONY: image-overlay
image-overlay:
	podman build --build-arg BASE=$(BASE) -t $(OVERLAY_IMAGE) -f Dockerfile.overlay .

# Directories containing shell scripts to lint and format
SCRIPT_DIRS := collection-scripts/ hack/ tests/

.PHONY: lint
lint: shellcheck
	find $(SCRIPT_DIRS) -type f -exec grep -Eq '^#!/' {} \; -exec $(SHELLCHECK) -x {} +

.PHONY: fmt
fmt: shfmt
	$(SHFMT) -l -w $(SCRIPT_DIRS)

.PHONY: test
test: bats
	$(BATS) tests/*.bats

## Location where binaries are installed
LOCALBIN ?= $(shell pwd)/tmp/bin

## Tool Binaries
BATS ?= $(LOCALBIN)/bats
SHFMT ?= $(LOCALBIN)/shfmt
SHELLCHECK ?= $(LOCALBIN)/shellcheck

# NOTE: please keep this list sorted so that it can be easily searched
TOOLS = bats \
        shfmt \
        shellcheck \

.PHONY: tools
tools:
	./hack/tools.sh

# Prefer the distribution's packages over downloading release binaries from
# GitHub: it works in environments restricted to already-configured package
# repositories, and needs no root. hack/tools.sh remains the fallback for
# anything the distribution does not carry.
.PHONY: tools-from-packages
tools-from-packages:
	./hack/tools-from-packages.sh

$(TOOLS):
	@if [ -x "$(LOCALBIN)/$@" ]; then \
		echo "$@ already present in $(LOCALBIN)"; \
	elif ./hack/tools-from-packages.sh $@; then \
		:; \
	else \
		echo "falling back to downloading $@"; \
		./hack/tools.sh $@; \
	fi

# Shell lint and tests without going through the build-machinery-go include.
#
# Upstream's `lint` and `test` targets do the same work, but the included
# golang.mk attaches test-unit to `test` and hard-requires a Go toolchain, so
# `make test` cannot run in an environment that only needs to check shell.
# These names do not collide with upstream's or build-machinery's, and CI
# uses them so that CI and a laptop run exactly the same thing.
# depends on the bare tool names, which the $(TOOLS) rule above provides
.PHONY: bats-lint
bats-lint: shellcheck
	find $(SCRIPT_DIRS) -type f -not -path '*/vendor/*' \
		-exec grep -Eq '^#!/' {} \; -exec $(SHELLCHECK) -x {} +

.PHONY: bats-test
bats-test: bats
	$(BATS) tests/*.bats

.PHONY: bats-check
bats-check: bats-lint bats-test
