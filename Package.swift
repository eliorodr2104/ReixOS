// swift-tools-version: 6.0
import Foundation
import PackageDescription

// FREESTANDING=1 is exported by the build (see Makefile) to compile the real
// bare-metal image: Embedded mode, whole-module, strict alignment, etc.
//
// Without it — e.g. when SourceKit-LSP or Xcode index the package for the host
// (arm64-apple-macosx) — those flags are dropped so the editor can load the
// macOS standard library and provide code intelligence.
// (0xKSor, thanks)
let isFreestanding = ProcessInfo.processInfo.environment["FREESTANDING"] == "1"

// @_extern stays on in both modes so the editor resolves the @_extern(c) shims.
var bareMetal: [SwiftSetting] = [
    .enableExperimentalFeature("Extern"),
]
if isFreestanding {
    bareMetal += [
        .enableExperimentalFeature("Embedded"),
        // -Xcc -mstrict-align injects +strict-align into Swift codegen, so LLVM
        // never emits unaligned multi-register accesses; those fault while the
        // MMU is off in early boot (before the VMM maps RAM as Normal memory).
        .unsafeFlags(["-Osize", "-wmo", "-parse-as-library", "-g", "-Xcc", "-mstrict-align"]),
    ]
}

// Non-Swift files that live under Sources/ReixKernel but are NOT part of the
// kernel's Swift module: the `reix` plugin compiles them with clang. SPM forbids
// mixing Swift and C/asm in one target, so they are excluded here.
let kernelNativeExclude: [String] = [
    "Arch/aarch64/Boot/boot.S",
    "Arch/aarch64/CPU/Handlers/CpuHandlers.S",
    "Arch/aarch64/ContextSwitch/ContextSwitch.S",
    "Arch/aarch64/Exceptions/Handlers/ContextSaving.S",
    "Arch/aarch64/MMU/Handlers/AArch64MMUHandlers.S",
    "Arch/aarch64/Timer/Handlers/VirtualTimer.S",
]

func app(_ name: String, _ settings: [SwiftSetting]) -> Target {
    .target(name: name, dependencies: ["Reix"], path: "Sources/Userland/\(name)", swiftSettings: settings)
}

let package = Package(
    name: "ReixOS",
    // Only affects host (editor/SourceKit) builds — the bare-metal triple
    // ignores it. macOS 26 makes InlineArray & co. available for indexing.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ReixABI", type: .static, targets: ["ReixABI"]),
        .library(name: "Reix",    type: .static, targets: ["Reix"]),
        .library(name: "Kernel",  type: .static, targets: ["Kernel"]),
        .library(name: "Init",          type: .static, targets: ["Init"]),
        .library(name: "Child",         type: .static, targets: ["Child"]),
        .library(name: "Child2",        type: .static, targets: ["Child2"]),
        .library(name: "NameServer",    type: .static, targets: ["NameServer"]),
        .library(name: "ProcessServer", type: .static, targets: ["ProcessServer"]),
    ],
    targets: [
        // Shared ABI: IPC types + syscall numbers. No dependencies.
        .target(name: "ReixABI", path: "Sources/ReixABI", swiftSettings: bareMetal),

        // Userland SDK: syscall wrappers + service clients. Re-exports ReixABI.
        .target(name: "Reix", dependencies: ["ReixABI"], path: "Sources/Reix", swiftSettings: bareMetal),

        // Kernel: everything else. Imports the header-only CElf module via -I.
        .target(
            name: "Kernel",
            dependencies: ["ReixABI"],
            path: "Sources/ReixKernel",
            exclude: kernelNativeExclude,
            swiftSettings: bareMetal
        ),

        // Userland apps: one ELF each, depend only on Reix.
        app("Init", bareMetal), app("Child", bareMetal), app("Child2", bareMetal),
        app("NameServer", bareMetal), app("ProcessServer", bareMetal),

        // Bare-metal orchestrator: link + objcopy + tar + qemu over the .a files
        // produced by `FREESTANDING=1 swift build --triple aarch64-none-none-elf`.
        .plugin(
            name: "reix",
            capability: .command(
                intent: .custom(verb: "reix", description: "Link kernel.bin + initrd.tar from the SPM modules (optionally run QEMU)"),
                permissions: [
                    .writeToPackageDirectory(reason: "writes kernel.elf/kernel.bin/*.elf/initrd.tar into the project directory")
                ]
            ),
            path: "Plugins/reix"
        ),
    ],
    swiftLanguageModes: [.v5]
)
