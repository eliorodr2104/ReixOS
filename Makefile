# Thin convenience wrapper around the `reix` CLI in Tools/reix.
#
#   reix           compiles the modules, then links kernel.bin + initrd.tar
#   this Makefile  names the profiles, provisions the disk and boots QEMU
#
# Every artifact lands in $(OUT) — nothing is written to the project root.
#
# Targets:
#   make            build the bootable image (debug)
#   make build      alias for the above (Xcode's legacy target passes $(ACTION))
#   make test       run the host unit tests, then the QEMU scenario matrix
#   make boot-modes build and boot all three BOOT_MODE profiles, checking each
#                   one prints what its contract says and no more
#   make host-test  host unit tests plus the terminal transport harness
#   make vm-test    only the QEMU scenario matrix
#   make terminal-baseline-4m  run the instrumented terminal baseline at 4 MiB
#   make run        build + boot in QEMU (BOOT_MODE=standard unless overridden)
#   make boot       boot what is already built, compiling nothing
#   make release    build + boot the optimized image
#   make smoke      build + boot headless, pass/fail on the serial log
#   make run-4m     build + boot in 4 MiB of RAM (the project's floor)
#   make smoke-4m   the headless version of the above
#   make clean-image  remove only $(OUT), keep the compiled modules
#   make clean      remove $(OUT) and the SwiftPM build directory
#   make prune-stale remove objects whose source is gone

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
# Output directory used by the CLI. Keep in sync with `outputDir` in
# Tools/reix/Sources/ReixBuild/BuildPipeline.swift and with the QEMU arguments
# in the Xcode scheme.
OUT         := .reix
# SwiftPM build tree. The profiling image needs its own graph because Package.swift
# derives compile defines from TERMINAL_PROFILE and SwiftPM does not key its
# manifest cache on arbitrary environment variables.
# Keep bare-metal products out of SwiftPM's host build database. `ReixApp` is a
# host executable and may run immediately before a cross rebuild; sharing one
# scratch tree makes llbuild reuse registrations for the wrong graph.
#
# One tree per boot mode: see BOOT_MODE below.
BUILD_PATH  ?= .build-freestanding-$(BOOT_MODE)

# How much of its own bring-up the image says out loud. See BootMode in ReixABI:
#   standard    the banner, then the shell. What `make run` boots.
#   verbose     the five macro phases of the boot, and nothing else.
#   diagnostic  one line per subsystem, kernel and userland. What the smoke
#               tests and the QEMU matrix boot, because their markers are
#               those lines.
#
# Presentation only. None of the three enables a self-test, fault injection or
# profiling the other two lack; REIX_RUNTIME_DIAGNOSTIC and its neighbours are
# separate knobs and stay that way.
#
# Checked here rather than by the compiler so a typo costs no build at all. The
# mode is part of BUILD_PATH above because SwiftPM does not key its manifest
# cache on arbitrary environment variables: one scratch tree per mode is what
# makes `make run BOOT_MODE=verbose` recompile instead of relinking yesterday's
# objects.
BOOT_MODE   ?= standard
ifeq ($(filter $(BOOT_MODE),standard verbose diagnostic),)
$(error BOOT_MODE must be standard, verbose or diagnostic, got '$(BOOT_MODE)')
endif
export BOOT_MODE

# QEMU: resolved from PATH by default (Homebrew on macOS, distro package on Linux).
#
# `pmu=on` gives the guest a PMUv3 block, which the kernel enables at boot and
# both the trace's pmuSection records and userland's PMUSection read. Without it
# the kernel leaves profiling counters disabled and continues booting.
#
# QemuMachine.swift in Tools/reix is the canonical definition. Keep this string
# in sync with it, with the QEMU_FLAGS default in scripts/smoke.sh and with the
# Xcode scheme: four places boot this kernel and all four have to agree.
QEMU        ?= qemu-system-aarch64
QEMU_FLAGS  := -machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic

# The disk. `virtio-blk-device` binds to one of the machine's virtio-mmio slots,
# which is the transport the block driver discovers by probing; without it the
# thirty-two slots are all empty and the kernel simply finds no block device.
#
# Created when missing and never migrated. The image survives across runs, so a
# volume formatted by one boot is mounted by the next; `make clean-image` takes
# it with $(OUT), which is how a run starts from a blank disk on purpose.
DISK        := $(OUT)/disk.img
DISK_SIZE   := 16M
QEMU_DISK    = -drive file=$(DISK),if=none,format=raw,id=reixdisk \
               -device virtio-blk-device,drive=reixdisk

# Guest RAM. Empty means the machine default, which is what every invocation
# here used before this knob existed; `make run MEM=8M` overrides it.
MEM         ?=

# Where the guest finds the initrd. `qemu` hands the archive over with -initrd;
# `embedded` passes no -initrd and leaves the kernel with the copy the image
# phase links into kernel.bin under `.initrd`.
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

# The same two knobs as the CLI spells them. QEMU_FLAGS and QEMU_DISK have no
# counterpart here: `reix run` builds that part of the line from QemuMachine.
REIX_MEM     = $(if $(MEM),--mem $(MEM))
REIX_INITRD  = $(if $(filter embedded,$(INITRD_MODE)),--embedded-initrd)

# Selects the bare-metal flags in Package.swift (Embedded, -wmo, strict-align…).
# Required for the cross build; when unset, SourceKit/Xcode index for the host
# instead and get working code intelligence.
export FREESTANDING := 1

.PHONY: all build image release app programs programs-release run boot run-release run-4m smoke smoke-4m test host-test performance-test vm-test boot-modes terminal-baseline-4m disk prune-stale clean-image clean

all: image

# Xcode's External Build System target invokes `make $(ACTION)`. Today Xcode
# passes an empty ACTION for a build, so it lands on `all` — this alias makes
# the integration work either way instead of relying on that detail.
build: image

# Remove objects whose source is gone.
#
# SwiftPM keeps the compiled object of a deleted or renamed source, and the
# archive keeps it as a member, so the linker is handed the same type twice and
# reports `duplicate symbol` against a file that is not in the tree any more.
prune-stale:
	@sh scripts/prune-stale.sh

# Prune, compile and link, all of it inside the `reix` CLI. It replaces both the
# bare `swift build` and the command plugin, which no longer exists.
image:
	@SWIFT=$(SWIFT) REIX_BUILD_PATH=$(BUILD_PATH) ./reix build

release:
	@SWIFT=$(SWIFT) REIX_BUILD_PATH=$(BUILD_PATH) ./reix build --release

# Boot in QEMU (Ctrl-A X to quit). The disk marker, the refusal to boot twice
# over one image and the terminal restore all live in the CLI now, signals
# included; the recipes below only name the profile.
#
# `boot` compiles nothing and installs nothing: the loop for changing one
# userland program is `make app APP=Shell` and then this, which never opens
# kernel.bin or initrd.tar and so cannot rebuild them.
#
# A running guest owns the disk. `make app` refuses while it does, and it is
# right to: the image under a live QEMU is a file two writers disagree about.
# Stop the guest (`shell.halt()` inside it, or Ctrl-A X) before installing.
boot:
	@SWIFT=$(SWIFT) REIX_BUILD_PATH=$(BUILD_PATH) ./reix boot $(REIX_MEM) $(REIX_INITRD)

run:
	@SWIFT=$(SWIFT) REIX_BUILD_PATH=$(BUILD_PATH) ./reix run $(REIX_MEM) $(REIX_INITRD)

run-release:
	@SWIFT=$(SWIFT) REIX_BUILD_PATH=$(BUILD_PATH) ./reix run --release $(REIX_MEM) $(REIX_INITRD)

# Headless boot smoke test: no human at the serial port, script watches the
# log for the SHM-OK line (success) or a panic/SHM-FAIL (failure) instead.
#
# `diagnostic` because the markers this watches for are the per-subsystem
# readiness lines, which are exactly what the other two modes leave out.
smoke: BOOT_MODE := diagnostic
smoke: programs
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS) $(QEMU_DISK)' MEM='$(MEM)' \
	    INITRD_MODE='$(INITRD_MODE)' OUT=$(OUT) scripts/smoke.sh

disk: $(DISK)

$(DISK):
	@mkdir -p $(OUT)
	qemu-img create -f raw $(DISK) $(DISK_SIZE) >/dev/null

# Provision ordinary programs through the same ReixFS implementation the guest
# mounts. This is deliberately offline: the importer refuses $(DISK).live, and
# every managed QEMU path below creates that marker before opening the image.
programs: image disk
	@FREESTANDING= $(SWIFT) run -q ReixApp install --format-if-blank \
		--disk $(DISK) $(OUT)/stripped/Shell.elf $(OUT)/stripped/Top.elf

programs-release: release disk
	@FREESTANDING= $(SWIFT) run -q ReixApp install --format-if-blank \
		--disk $(DISK) $(OUT)/stripped/Shell.elf $(OUT)/stripped/Top.elf

# One-program development loop. Example: `make app APP=Shell` recompiles,
# relinks, validates, and installs only Shell. It never opens kernel.bin or
# initrd.tar, which makes their unchanged hashes a mechanical release gate.
#
# The build below is the whole graph and not `--target $(APP)`: building one
# target compiles its objects without archiving the `.a` files, so the link
# step below would take a fresh app and stale libraries. It is incremental
# either way; what it costs is the kernel's objects, not a rebuild of them.
APP ?= Shell
app: disk
	@FREESTANDING=1 $(SWIFT) build --triple $(TRIPLE) --scratch-path $(BUILD_PATH) -q
	@SWIFT=$(SWIFT) FREESTANDING=1 REIX_BUILD_PATH=$(BUILD_PATH) ./reix app link $(APP)
	@FREESTANDING= $(SWIFT) run -q ReixApp install --format-if-blank \
		--disk $(DISK) $(OUT)/stripped/$(APP).elf

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
# Tools/reix is its own package, so the root `swift test` cannot see it. Its
# suite runs here, from the same target, because nothing else would run it.
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
host-test: prune-stale
	@mkdir -p $(OUT)
	$(SWIFT) test --no-parallel --xunit-output $(OUT)/test-results.xml
	$(SWIFT) test --package-path Tools/reix
	$(SWIFT) run TerminalRingHarness
	$(SWIFT) run InputRouterHarness
	$(SWIFT) run SerialRingHarness
	$(SWIFT) run VTDecoderHarness
	$(SWIFT) run ShellCatalogHarness
	$(SWIFT) run SbrkHeapHarness
	SWIFT=$(SWIFT) sh scripts/test-trace-interaction.sh
	sh scripts/test-scenario-artifact-isolation.sh

# Timing thresholds run only in an optimized, unsanitized host build. The same
# tests still exercise their functional oracle in host-test and ASan runs.
#
# Two lines, and both are needed: a target-specific variable line carries no
# recipe, so the rule below is what make actually runs.
performance-test: FREESTANDING :=
performance-test:
	REIX_PERFORMANCE_GATES=1 $(SWIFT) test -c release --no-parallel \
	    --scratch-path $(OUT)/build-performance --filter FileSystemTests.OptimisationTests

# The QEMU scenario matrix: every row in Tests/Scenarios/scenarios.tsv, booted
# one at a time by scripts/scenarios.sh over the same scripts/smoke.sh that
# `make smoke` uses. Logs land in $(OUT)/scenario-<id>.log and the JUnit report
# in $(OUT)/scenario-results.xml, next to the host suite's xUnit one.
#
# FREESTANDING stays set here, unlike host-test: this target builds the image,
# and a target-specific variable applies to a target's prerequisites too, so
# clearing it would break the cross build. The one post-check that needs a host
# toolchain clears it around its own `swift` call instead.
vm-test: BOOT_MODE := diagnostic
vm-test: programs
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS) $(QEMU_DISK)' SWIFT=$(SWIFT) OUT=$(OUT) \
	    scripts/scenarios.sh

# The three boot profiles, each built and booted to the same shell prompt, each
# checked against what its own mode is allowed to print. Not part of `test`: it
# is two extra cross builds, and vm-test already covers the diagnostic image.
boot-modes:
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS) $(QEMU_DISK)' OUT=$(OUT) MAKE='$(MAKE)' \
	    DISK=$(DISK) scripts/boot-modes.sh

terminal-baseline-4m: export TERMINAL_PROFILE := 1
terminal-baseline-4m: BOOT_MODE  := diagnostic
terminal-baseline-4m: BUILD_PATH := .build-terminal-profile
# Same disk + StorageCheck + Shell.help/exit workload as the normal mixed row.
# The instrumented image additionally emits the metric snapshot.
terminal-baseline-4m: programs
	QEMU=$(QEMU) QEMU_FLAGS='$(QEMU_FLAGS) $(QEMU_DISK)' DISK=$(DISK) \
	    SWIFT=$(SWIFT) OUT=$(OUT) scripts/scenarios.sh mixed-profile-4m

clean-image:
	rm -rf $(OUT)

clean: clean-image
	rm -rf .build .build-freestanding .build-freestanding-* .build-terminal-profile
