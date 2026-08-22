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
#   make test       run the host unit tests, then the QEMU scenario matrix
#   make host-test  only the host unit tests (no QEMU, no bare-metal build)
#   make vm-test    only the QEMU scenario matrix
#   make run        build + boot in QEMU
#   make release    build + boot the optimized image
#   make smoke      build + boot headless, pass/fail on the serial log
#   make run-4m     build + boot in 4 MiB of RAM (the project's floor)
#   make smoke-4m   the headless version of the above
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
#
# `pmu=on` gives the guest a PMUv3 block, which the kernel enables at boot and
# both the trace's pmuSection records and userland's PMUSection read. Without it
# the kernel leaves profiling counters disabled and continues booting.
#
# Keep this string in sync with the QEMU_FLAGS default in scripts/smoke.sh, with
# the `reix run` command in Plugins/reix/plugin.swift and with the Xcode scheme:
# four places boot this kernel and all four have to give it the same machine.
QEMU        ?= qemu-system-aarch64
QEMU_FLAGS  := -machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic

# Guest RAM. Empty means the machine default, which is what every invocation
# here used before this knob existed; `make run MEM=8M` overrides it.
MEM         ?=

# Where the guest finds the initrd. `qemu` hands the archive over with -initrd;
# `embedded` passes no -initrd and leaves the kernel with the copy the plugin
# links into kernel.bin under `.initrd`.
#
# This is a knob and not a detail because QEMU decides the layout: it drops an
# -initrd halfway up RAM and then 2 MiB-aligns the generated DTB after it, so
# below ~5 MiB that address lands past the top of RAM and QEMU exits with
# "Not enough space for DTB after kernel/initrd" before the kernel runs. With
# `embedded` there is nothing halfway up RAM and the DTB lands 2 MiB in.
# `MEM=4M` therefore needs `INITRD_MODE=embedded`; use `make run-4m`.
INITRD_MODE ?= qemu

# Recursively expanded on purpose: the -4m targets below set MEM and
# INITRD_MODE per target, and a := here would have resolved them away first.
QEMU_MEM     = $(if $(MEM),-m $(MEM))
QEMU_INITRD  = $(if $(filter embedded,$(INITRD_MODE)),,-initrd $(OUT)/initrd.tar)

# Selects the bare-metal flags in Package.swift (Embedded, -wmo, strict-align…).
# Required for the cross build; when unset, SourceKit/Xcode index for the host
# instead and get working code intelligence.
export FREESTANDING := 1

.PHONY: all build image release run run-release run-4m smoke smoke-4m test host-test vm-test prune-dups clean-image clean

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
	@sh scripts/prune-stale.sh

# Build all modules, then link the image via the plugin.
image: prune-dups
	$(SWIFT) build --triple $(TRIPLE)
	$(SWIFT) package $(PLUGIN)

release: prune-dups
	$(SWIFT) build --triple $(TRIPLE) -c release
	$(SWIFT) package $(PLUGIN) --release

# Boot in QEMU (Ctrl-A X to quit). qemu runs here, not inside the plugin sandbox.
run: image
	$(QEMU) $(QEMU_FLAGS) $(QEMU_MEM) -kernel $(OUT)/kernel.bin $(QEMU_INITRD)

run-release: release
	$(QEMU) $(QEMU_FLAGS) $(QEMU_MEM) -kernel $(OUT)/kernel.bin $(QEMU_INITRD)

# Headless boot smoke test: no human at the serial port, script watches the
# log for the SHM-OK line (success) or a panic/SHM-FAIL (failure) instead.
smoke: image
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS)' MEM='$(MEM)' \
	    INITRD_MODE='$(INITRD_MODE)' OUT=$(OUT) scripts/smoke.sh

# The 4 MiB floor the project targets, as a target rather than a hand-typed
# invocation. Both variables are load-bearing; see INITRD_MODE above.
run-4m: MEM         := 4M
run-4m: INITRD_MODE := embedded
run-4m: run

smoke-4m: MEM         := 4M
smoke-4m: INITRD_MODE := embedded
smoke-4m: smoke

# Host unit tests: Tests/KernelPolicyTests (syscall and policy paths),
# Tests/KernelUnitTests (the memory subsystem over host arenas) and
# Tests/ABILayoutTests (sizes and strides only), over the kernel modules compiled
# for arm64-apple-macosx. No QEMU and no bare-metal build is involved.
#
# `test` is the name to use; `host-test` and `vm-test` are the two halves, and
# either can be run on its own.
#
# FREESTANDING has to be *cleared*: Package.swift only puts the test targets in
# the graph when it is unset, because the Embedded flags the cross build needs
# cannot compile for the host. The target-specific assignment below is enough,
# the `export` above still applies and hands the child an empty value.
#
# --no-parallel is load-bearing, not a speed knob. Several suites own kernel
# globals (LogSink, TraceRing, ProcessStatsIndex, the PMU register fake, the
# shim's barrier counter, Kernel.platformInfo) and `.serialized` only orders the
# tests inside one suite, never two suites against each other. Each of those
# suites repeats this above its @Suite so the flag is not "optimised" away.
#
# swift-testing appends its own suffix to --xunit-output, so the report lands in
# $(OUT)/test-results-swift-testing.xml. `swift test` exits non-zero on failure,
# which is what fails this target.
#
# Xcode, both halves of it:
#   * ReixOS.xcodeproj carries `Tests` as a synchronized group, so the files are
#     editable in the project the `ReixOS` scheme lives in, and the shared
#     `ReixOSTests` scheme is a second legacy target whose external build tool is
#     `make test`. Select it and press cmd-B: the tally lands in the build log and
#     a failed expectation fails the build. There is no cmd-U here, a legacy
#     target has no test bundle for Xcode to run.
#   * cmd-U and the test navigator do work on the package itself: open
#     Package.swift and use the autogenerated `ReixOS-Package` scheme. Xcode's own
#     toolchain compiles the host targets fine, it is only the bare-metal triple
#     that needs the swiftly one. Turn "Execute in parallel" off in the test
#     action first, for the reason --no-parallel is here.
# host-test comes first on purpose: it is the cheap half, and there is no point
# spending a cross build and six QEMU boots on a tree whose unit tests are red.
# Sequential either way, which -j does not change here since vm-test owns QEMU.
test: host-test vm-test

host-test: FREESTANDING :=
host-test: prune-dups
	@mkdir -p $(OUT)
	$(SWIFT) test --no-parallel --xunit-output $(OUT)/test-results.xml

# The QEMU scenario matrix: every row in Tests/Scenarios/scenarios.tsv, booted
# one at a time by scripts/scenarios.sh over the same scripts/smoke.sh that
# `make smoke` uses. Logs land in $(OUT)/scenario-<id>.log and the JUnit report
# in $(OUT)/scenario-results.xml, next to the host suite's xUnit one.
#
# FREESTANDING stays set here, unlike host-test: this target builds the image,
# and a target-specific variable applies to a target's prerequisites too, so
# clearing it would break the cross build. The one post-check that needs a host
# toolchain clears it around its own `swift` call instead.
vm-test: image
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS)' SWIFT=$(SWIFT) OUT=$(OUT) \
	    scripts/scenarios.sh

clean-image:
	rm -rf $(OUT)

clean: clean-image
	rm -rf .build
