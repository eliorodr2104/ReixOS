# Thin convenience wrapper around the SwiftPM build + the `reix` plugin.
#
#   SPM            compiles the Swift modules into static libraries (.a)
#   reix plugin    links kernel.bin + initrd.tar from those libraries
#   this Makefile  ties them together and boots QEMU
#
# Every artifact lands in $(OUT) — nothing is written to the project root.
#
# Targets:
#   make            build the bootable image (debug)
#   make build      alias for the above (Xcode's legacy target passes $(ACTION))
#   make run        build + boot in QEMU
#   make release    build + boot the optimized image
#   make smoke      build + boot headless, pass/fail on the serial log
#   make clean-image  remove only $(OUT), keep the compiled modules
#   make clean      remove $(OUT) and the SwiftPM build directory
#   make prune-dups remove iCloud conflict copies from the build trees

# Toolchain discovery. Override either on the command line if needed:
#     make SWIFT=/path/to/swift QEMU=/path/to/qemu-system-aarch64
#
# Swift: a plain `swift` on PATH may resolve to Xcode's toolchain, which lacks
# the Embedded stdlib for the bare-metal triple (you'd see "unable to load
# standard library for target aarch64-none-none-elf"). Prefer a swiftly-managed
# toolchain (6.3.x ships the Embedded stdlib) when one is installed, else PATH.
SWIFTLY_SWIFT := $(wildcard $(HOME)/.swiftly/bin/swift)
SWIFT       ?= $(if $(SWIFTLY_SWIFT),$(SWIFTLY_SWIFT),swift)
TRIPLE      := aarch64-none-none-elf
PLUGIN      := --allow-writing-to-package-directory reix
# Output directory used by the plugin. Keep in sync with `outputDir` in
# Plugins/reix/plugin.swift and with the QEMU arguments in the Xcode scheme.
OUT         := .reix
# QEMU: resolved from PATH by default (Homebrew on macOS, distro package on Linux).
QEMU        ?= qemu-system-aarch64
QEMU_FLAGS  := -machine virt,gic-version=2 -cpu cortex-a53 -nographic

# Selects the bare-metal flags in Package.swift (Embedded, -wmo, strict-align…).
# Required for the cross build; when unset, SourceKit/Xcode index for the host
# instead and get working code intelligence.
export FREESTANDING := 1

.PHONY: all build image release run run-release smoke prune-dups clean-image clean

all: image

# Xcode's External Build System target invokes `make $(ACTION)`. Today Xcode
# passes an empty ACTION for a build, so it lands on `all` — this alias makes
# the integration work either way instead of relying on that detail.
build: image

# Drop the "<name> 2.ext" copies iCloud leaves behind in the build trees.
#
# This package lives under a synced ~/Documents, so every build rewrites several
# megabytes that the file provider is trying to upload; when the two race it
# keeps both versions and renames one. They are regenerable artifacts, but a
# stale copy is indistinguishable from a real one when reading the output
# directory by hand, and one of them was read as current during an audit.
#
# The pattern requires a space before the digit on purpose: `Child2.elf` and
# `Child2.build` are real targets and a broader glob would delete them. `find`
# rather than a shell glob because a non-matching glob aborts the recipe.
#
# Two shapes, and both are needed. Files may or may not have an extension
# (`debug 2.yaml`, but also `plugins 2`), so the name pattern cannot require a
# dot. Directories have to be removed with `rm -rf`: `-delete` refuses a
# non-empty one, and `.build` conflict copies are routinely whole trees
# (`checkouts 2`, `ReixKernel 2.build`). `-prune` stops the walk from descending
# into a tree that is about to go away.
prune-dups:
	@find $(OUT) .build -depth -name "* [0-9]" -o -name "* [0-9].*" 2>/dev/null \
	    | while IFS= read -r dup; do rm -rf "$$dup"; done || true

# Build all modules, then link the image via the plugin.
image: prune-dups
	$(SWIFT) build --triple $(TRIPLE)
	$(SWIFT) package $(PLUGIN)

release: prune-dups
	$(SWIFT) build --triple $(TRIPLE) -c release
	$(SWIFT) package $(PLUGIN) --release

# Boot in QEMU (Ctrl-A X to quit). qemu runs here, not inside the plugin sandbox.
run: image
	$(QEMU) $(QEMU_FLAGS) -kernel $(OUT)/kernel.bin -initrd $(OUT)/initrd.tar

run-release: release
	$(QEMU) $(QEMU_FLAGS) -kernel $(OUT)/kernel.bin -initrd $(OUT)/initrd.tar

# Headless boot smoke test: no human at the serial port, script watches the
# log for the SHM-OK line (success) or a panic/SHM-FAIL (failure) instead.
smoke: image
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS)' OUT=$(OUT) scripts/smoke.sh

clean-image:
	rm -rf $(OUT)

clean: clean-image
	rm -rf .build
