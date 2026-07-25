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
#   make clean-image  remove only $(OUT), keep the compiled modules
#   make clean      remove $(OUT) and the SwiftPM build directory

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

.PHONY: all build image release run run-release clean-image clean

all: image

# Xcode's External Build System target invokes `make $(ACTION)`. Today Xcode
# passes an empty ACTION for a build, so it lands on `all` — this alias makes
# the integration work either way instead of relying on that detail.
build: image

# Build all modules, then link the image via the plugin.
image:
	$(SWIFT) build --triple $(TRIPLE)
	$(SWIFT) package $(PLUGIN)

release:
	$(SWIFT) build --triple $(TRIPLE) -c release
	$(SWIFT) package $(PLUGIN) --release

# Boot in QEMU (Ctrl-A X to quit). qemu runs here, not inside the plugin sandbox.
run: image
	$(QEMU) $(QEMU_FLAGS) -kernel $(OUT)/kernel.bin -initrd $(OUT)/initrd.tar

run-release: release
	$(QEMU) $(QEMU_FLAGS) -kernel $(OUT)/kernel.bin -initrd $(OUT)/initrd.tar

clean-image:
	rm -rf $(OUT)

clean: clean-image
	rm -rf .build
