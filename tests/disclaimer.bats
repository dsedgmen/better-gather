#!/usr/bin/env bats
#
# This is not a Red Hat product, and the people who read a must-gather are
# usually not the people who ran it. The disclaimer has to survive into the
# image and into the collection, so these assert the plumbing rather than the
# prose.

load test_helper

@test "DISCLAIMER exists and says the important things" {
	disclaimer="${PROJECT_ROOT}/DISCLAIMER"
	[ -f "$disclaimer" ]
	run cat "$disclaimer"
	[[ "$output" == *"NOT A RED HAT PRODUCT"* ]]
	[[ "$output" == *"not built, reviewed, supported or endorsed by Red Hat"* ]]
	[[ "$output" == *"WITHOUT WARRANTY"* ]]
	[[ "$output" == *"at your own risk"* ]]
}

@test "the overlay ships DISCLAIMER into the image" {
	run grep -E '^COPY DISCLAIMER /usr/share/better-gather/DISCLAIMER$' \
		"${PROJECT_ROOT}/Dockerfile.overlay"
	[ "$status" -eq 0 ]
}

@test "the overlay is labelled as not a Red Hat product" {
	run cat "${PROJECT_ROOT}/Dockerfile.overlay"
	[[ "$output" == *"better-gather.disclaimer="* ]]
	[[ "$output" == *"org.opencontainers.image.vendor="* ]]
	[[ "$output" == *"Not a Red Hat product"* ]]
}

@test "gather prints the disclaimer and puts it in the collection" {
	run cat "${SCRIPT_DIR}/gather"
	[[ "$output" == *"cat /usr/share/better-gather/DISCLAIMER"* ]]
	[[ "$output" == *"cp /usr/share/better-gather/DISCLAIMER /must-gather/DISCLAIMER"* ]]
}

# If the file is missing -- someone assembled an image without it -- gather
# must still say something rather than go quiet about provenance.
@test "gather falls back to a warning when the file is absent" {
	run cat "${SCRIPT_DIR}/gather"
	[[ "$output" == *"not a Red Hat product and is unsupported"* ]]
}

@test "the README leads with the disclaimer" {
	run head -30 "${PROJECT_ROOT}/README.md"
	[[ "$output" == *"Not a Red Hat product"* ]]
	[[ "$output" == *"at your own risk"* ]]
}

# Accepted scanner findings have to carry a reason, or .trivyignore quietly
# becomes the place inconvenient results go. A comment block documents every
# entry under it until the next blank line, so a group of related rules can
# share one explanation.
@test "every .trivyignore entry is commented" {
	ignore="${PROJECT_ROOT}/.trivyignore"
	[ -f "$ignore" ]
	documented=false
	undocumented=()
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"") documented=false ;;
		\#*) documented=true ;;
		*) [ "$documented" = true ] || undocumented+=("$line") ;;
		esac
	done <"$ignore"
	[ ${#undocumented[@]} -eq 0 ] || {
		echo "undocumented .trivyignore entries: ${undocumented[*]}" >&2
		return 1
	}
}
