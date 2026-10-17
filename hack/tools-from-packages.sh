#!/usr/bin/env bash
#
# Populate tmp/bin from already-configured package repositories.
#
# hack/tools.sh fetches bats, shfmt and shellcheck from GitHub releases. That
# is not possible in an environment restricted to the package repositories
# already configured on the machine, and it is not desirable in one that has
# them packaged anyway.
#
# This script gets the same tools from the distribution instead. It does not
# install anything system-wide and needs no root: the packages are downloaded
# and unpacked under tmp/, which is already gitignored.
#
# bats-support and bats-assert are deliberately not handled. Neither is
# packaged by Fedora or RHEL, and tests/bats_assert_fallback.bash provides
# local equivalents of the assertions the suite uses, so the suite runs
# without them.
#
# Usage:
#   hack/tools-from-packages.sh              # all tools
#   hack/tools-from-packages.sh bats         # just one
#
# Exits non-zero if a tool cannot be provided this way, so callers can fall
# back to hack/tools.sh.

set -eu -o pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
declare -r PROJECT_ROOT

declare -r LOCAL_BIN="$PROJECT_ROOT/tmp/bin"
declare -r RPM_CACHE="$PROJECT_ROOT/tmp/packages"
declare -r RPM_ROOT="$PROJECT_ROOT/tmp/pkgroot"

# tool -> package name
package_for() {
	case "$1" in
	bats) echo "bats" ;;
	shellcheck) echo "ShellCheck" ;;
	shfmt) echo "shfmt" ;;
	*) return 1 ;;
	esac
}

require() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "ERROR: $1 is required but not installed" >&2
		return 1
	}
}

fetch_package() {
	local package="$1"

	mkdir -p "$RPM_CACHE"
	if compgen -G "$RPM_CACHE/${package}-*.rpm" >/dev/null; then
		return 0
	fi

	echo "INFO: downloading ${package} from the configured repositories"
	# --destdir keeps it out of the working tree; no root needed.
	#
	# Try the distribution repositories first. A third-party repo that
	# happens to be configured can prompt to import a GPG key, which blocks
	# a non-interactive run over a key we have no need for. The fallback
	# passes -y so that prompt cannot hang the build either.
	if dnf download --quiet --destdir "$RPM_CACHE" \
		--repo=fedora --repo=updates "$package" >/dev/null 2>&1; then
		return 0
	fi
	if dnf download -y --quiet --destdir "$RPM_CACHE" "$package" >/dev/null 2>&1; then
		return 0
	fi

	echo "ERROR: ${package} is not available from the configured repositories" >&2
	return 1
}

unpack_package() {
	local package="$1" rpm

	mkdir -p "$RPM_ROOT"
	for rpm in "$RPM_CACHE/${package}"-*.rpm; do
		# Skip source rpms, which dnf download may also fetch.
		case "$rpm" in
		*.src.rpm) continue ;;
		esac
		rpm2cpio "$rpm" | (cd "$RPM_ROOT" && cpio -idm --quiet)
	done
}

link_tool() {
	local tool="$1" target

	mkdir -p "$LOCAL_BIN"
	target="$RPM_ROOT/usr/bin/$tool"
	if [[ ! -x "$target" ]]; then
		echo "ERROR: $tool not found in the unpacked package" >&2
		return 1
	fi

	# Symlink rather than copy so the tool resolves its own installation
	# root; bats in particular locates its libexec that way.
	ln -sf "$target" "$LOCAL_BIN/$tool"

	# Unpacking an rpm does not pull its dependencies, so a dynamically
	# linked tool can land here and then fail at the point of use with a
	# bare "cannot open shared object file". Catch that now and name the
	# package to install, rather than letting it surface as a lint failure.
	if ! "$LOCAL_BIN/$tool" --version >/dev/null 2>&1; then
		local why
		why="$("$LOCAL_BIN/$tool" --version 2>&1 | head -1)"
		echo "ERROR: $tool was unpacked but will not run: ${why}" >&2
		case "$why" in
		*libnuma*) echo "       install the numactl-libs package" >&2 ;;
		*"shared object"*) echo "       a runtime dependency of the package is missing" >&2 ;;
		esac
		return 1
	fi

	echo "OK: $tool -> $target"
}

install_tool() {
	local tool="$1" package

	package="$(package_for "$tool")" || {
		echo "ERROR: unknown tool '$tool'" >&2
		return 1
	}

	if [[ -x "$LOCAL_BIN/$tool" ]]; then
		echo "OK: $tool already present in tmp/bin"
		return 0
	fi

	fetch_package "$package"
	unpack_package "$package"
	link_tool "$tool"
}

main() {
	require dnf
	require rpm2cpio
	require cpio

	local tools=("$@")
	if [[ ${#tools[@]} -eq 0 ]]; then
		tools=(bats shellcheck shfmt)
	fi

	local tool
	for tool in "${tools[@]}"; do
		install_tool "$tool"
	done

	if [[ ! -d "$LOCAL_BIN/bats-assert" ]]; then
		echo "INFO: bats-assert/bats-support are not packaged;" \
			"tests/bats_assert_fallback.bash will be used instead"
	fi
}

main "$@"
