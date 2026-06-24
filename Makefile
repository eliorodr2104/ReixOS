# Thin convenience wrapper around the SwiftPM build + the `reix` plugin.
#
#   SPM            compiles the Swift modules into static libraries (.a)
#   reix plugin    links kernel.bin + initrd.tar from those libraries
#   this Makefile  ties them together and boots QEMU
#
# Targets:
#   make            build the bootable image (debug)
#   make run        build + boot in QEMU
#   make release    build + boot the optimized image
#   make clean      remove build artifacts

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
# QEMU: resolved from PATH by default (Homebrew on macOS, distro package on Linux).
QEMU        ?= qemu-system-aarch64
QEMU_FLAGS  := -machine virt,gic-version=2 -cpu cortex-a53 -nographic

# Selects the bare-metal flags in Package.swift (Embedded, -wmo, strict-align…).
# Required for the cross build; when unset, SourceKit/Xcode index for the host
# instead and get working code intelligence.
export FREESTANDING := 1

.PHONY: all image release run run-release clean

all: image

# Build all modules, then link the image via the plugin.
image:
	$(SWIFT) build --triple $(TRIPLE)
	$(SWIFT) package $(PLUGIN)

release:
	$(SWIFT) build --triple $(TRIPLE) -c release
	$(SWIFT) package $(PLUGIN) --release

# Boot in QEMU (Ctrl-A X to quit). qemu runs here, not inside the plugin sandbox.
run: image
	$(QEMU) $(QEMU_FLAGS) -kernel kernel.bin -initrd initrd.tar

run-release: release
	$(QEMU) $(QEMU_FLAGS) -kernel kernel.bin -initrd initrd.tar

clean:
	rm -rf .build
	rm -f kernel.elf kernel.bin initrd.tar *.elf
