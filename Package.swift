// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// True when the build is producing the real bare-metal image: Embedded mode,
/// whole-module, strict alignment, and so on. `FREESTANDING=1` is exported by
/// the build (see Makefile).
///
/// Without it, for instance when SourceKit-LSP or Xcode index the package for
/// the host (arm64-apple-macosx), those flags are dropped so the editor can load
/// the macOS standard library and provide code intelligence.
/// (0xKSor, thanks)
let isFreestanding = ProcessInfo.processInfo.environment["FREESTANDING"] == "1"

// @_extern stays on in both modes so the editor resolves the @_extern(c) shims.
var bareMetal: [SwiftSetting] = [
    .enableExperimentalFeature("Extern"),
]
if isFreestanding {
    bareMetal += [
        .enableExperimentalFeature("Embedded"),
        // -Xcc -mstrict-align is not optional: without it LLVM emits unaligned
        // multi-register accesses, which fault with the MMU off in early boot.
        .unsafeFlags([
            "-Osize", "-wmo", "-parse-as-library", "-g",
            "-Xcc", "-mstrict-align",

            // One section per function and per datum, so the userland link can
            // drop what no image reaches. Without them `-wmo` emits one object
            // per module and the linker has nothing finer than a module to
            // keep: every ELF carried the whole of Reix and ReixABI.
            "-Xfrontend", "-function-sections",
            "-Xcc", "-ffunction-sections", "-Xcc", "-fdata-sections",
        ]),
    ]
}

/// Non-Swift files that live under `Sources/ReixKernel` but are not part of the
/// kernel's Swift module: the `reix` plugin compiles them with clang. SPM forbids
/// mixing Swift and C/asm in one target, so they are excluded here.
let kernelNativeExclude: [String] = [
    "Arch/aarch64/Boot/boot.S",
    "Arch/aarch64/ContextSwitch/ContextSwitch.S",
    "Arch/aarch64/Exceptions/Handlers/ContextSaving.S",
]

func app(
    _ name    : String,
    _ settings: [SwiftSetting]
) -> Target {
    .target(name: name, dependencies: ["Reix"], path: "Sources/Userland/\(name)", swiftSettings: settings)
}

let package = Package(
    name: "ReixOS",
    // Only affects host (editor/SourceKit) builds; the bare-metal triple
    // ignores it. macOS 26 makes InlineArray & co. available for indexing.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ReixABI", type: .static, targets: ["ReixABI"]),
        .library(name: "Reix",    type: .static, targets: ["Reix"]),
        .library(name: "Kernel",  type: .static, targets: ["Kernel"]),
        .library(name: "Init",          type: .static, targets: ["Init"]),
        .library(name: "NameServer",    type: .static, targets: ["NameServer"]),
        .library(name: "ConsoleServer", type: .static, targets: ["ConsoleServer"]),
        .library(name: "Top",           type: .static, targets: ["Top"]),
        .library(name: "Shell",         type: .static, targets: ["Shell"]),
        .library(name: "ShellLanguage", type: .static, targets: ["ShellLanguage"]),
        .library(name: "ReixFS",        type: .static, targets: ["ReixFS"]),
        .library(name: "TerminalServer", type: .static, targets: ["TerminalServer"]),
        .library(name: "VirtioBus",     type: .static, targets: ["VirtioBus"]),
        .library(name: "BlockServer",   type: .static, targets: ["BlockServer"]),
        .library(name: "FileSystemServer", type: .static, targets: ["FileSystemServer"]),
        .library(name: "StorageCheck",  type: .static, targets: ["StorageCheck"]),
    ],
    targets: [
        // Shared ABI: IPC types + syscall numbers. No dependencies.
        .target(name: "ReixABI", path: "Sources/ReixABI", swiftSettings: bareMetal),

        // Userland SDK: syscall wrappers + service clients. Re-exports ReixABI.
        .target(name: "Reix", dependencies: ["ReixABI"], path: "Sources/Reix", swiftSettings: bareMetal),

        // Kernel: everything else. Imports the header-only CElf module via -I.
        .target(
            name         : "Kernel",
            dependencies : ["ReixABI"],
            path         : "Sources/ReixKernel",
            exclude      : kernelNativeExclude,
            swiftSettings: bareMetal
        ),

        // Userland apps: one ELF each, depend only on Reix.
        app("Init", bareMetal),
        app("NameServer", bareMetal), app("ConsoleServer", bareMetal),
        app("Top", bareMetal), app("TerminalServer", bareMetal),

        // The two processes the disk needs: the walker that reads device ids
        // off the bus, and the driver it starts for what it found.
        app("VirtioBus", bareMetal), app("BlockServer", bareMetal),

        // The one program that holds nothing: it exercises the whole storage
        // stack through capabilities somebody handed it.
        app("StorageCheck", bareMetal),
        .target(
            name         : "FileSystemServer",
            dependencies : ["Reix", "ReixFS"],
            path         : "Sources/Userland/FileSystemServer",
            swiftSettings: bareMetal
        ),

        // The shell language is userland implementation, not a kernel facility.
        // It is deliberately SDK-free: syntax, resolution and typed values are
        // exercised on the host, while the executable supplies capabilities via
        // public Reix protocols only.
        .target(
            name         : "ShellLanguage",
            dependencies : ["ReixABI"],
            path         : "Sources/Userland/Shell/Language",
            swiftSettings: bareMetal
        ),

        // The on-disk format and everything that reads or writes it, over any
        // `BlockDevice`. No syscalls, so a host suite can mount it on a slab of
        // memory and exercise the whole thing without a disk.
        .target(
            name         : "ReixFS",
            dependencies : ["ReixABI"],
            path         : "Sources/ReixFS",
            swiftSettings: bareMetal
        ),
        .target(
            name         : "Shell",
            dependencies : ["Reix", "ShellLanguage"],
            path         : "Sources/Userland/Shell",
            exclude      : ["Language"],
            swiftSettings: bareMetal
        ),

    ] + (isFreestanding ? [] : [
        .executableTarget(
            name        : "ShellBench",
            dependencies: ["ShellLanguage", "ReixABI"],
            path        : "Tests/ShellBench"
        ),

        .target(
            name             : "KernelHostShims",
            path             : "Tests/KernelHostShims",
            publicHeadersPath: "include"
        ),

        // Fixtures shared by the host suites. Its own target because SwiftPM
        // forbids a target reaching for sources outside its own directory.
        .target(
            name: "KernelTestSupport",
            // `@testable import Kernel` inside makes this debug-only: a host
            // `-c release` build fails ModuleNotTestable. `make release` is fine.
            dependencies: ["Kernel", "ReixABI"],
            path: "Tests/Support"
        ),

        .testTarget(
            name        : "KernelPolicyTests",
            dependencies: ["Kernel", "ReixABI", "KernelHostShims", "KernelTestSupport"],
            path        : "Tests/KernelPolicyTests"
        ),

        // The shell's command language, which is the one piece of it that is
        // pure logic: a line in, a parsed command or a placed error out.
        .testTarget(
            name        : "ShellTests",
            dependencies: ["ShellLanguage"],
            path        : "Tests/ShellTests"
        ),

        // The file system over a slab of host memory: format, allocate, name,
        // grow and delete, with no disk and no kernel anywhere near it.
        .testTarget(
            name        : "FileSystemTests",
            dependencies: ["ReixFS", "ReixABI"],
            path        : "Tests/FileSystemTests"
        ),

        // The pipe's wire format, over nothing at all: frames, acknowledgements
        // and the transfer state, with no shared page and no syscalls.
        .testTarget(
            name        : "PipeTests",
            dependencies: ["ReixABI"],
            path        : "Tests/PipeTests"
        ),

        // The shell frame and the terminal's events, decoded and encoded on the
        // host: a wire format is exactly the thing worth exercising without a
        // machine at either end of it.
        .testTarget(
            name        : "ShellProtocolTests",
            dependencies: ["ReixABI", "ShellLanguage"],
            path        : "Tests/ShellProtocolTests"
        ),

        // Layout locks only: sizes, strides and the all-zero patterns the wire
        // formats and the per-frame records depend on. No behaviour is exercised.
        .testTarget(
            name        : "ABILayoutTests",
            dependencies: ["Kernel", "ReixABI", "KernelHostShims", "KernelTestSupport"],
            path        : "Tests/ABILayoutTests"
        ),

        // The memory subsystem in isolation: buddy allocator, slab core, physical
        // page manager, VMA list and page retirement, over host-owned arenas.
        .testTarget(
            name        : "KernelUnitTests",
            dependencies: ["Kernel", "ReixABI", "KernelHostShims", "KernelTestSupport"],
            path        : "Tests/KernelUnitTests"
        ),
    ]) + [
        // Bare-metal orchestrator: link + objcopy + tar + qemu over the .a files
        // produced by `FREESTANDING=1 swift build --triple aarch64-none-none-elf`.
        .plugin(
            name: "reix",
            capability: .command(
                intent: .custom(verb: "reix", description: "Link kernel.bin + initrd.tar from the SPM modules (optionally run QEMU)"),
                permissions: [
                    .writeToPackageDirectory(reason: "writes kernel.elf/kernel.bin/*.elf/initrd.tar into .reix/")
                ]
            ),
            path: "Plugins/reix"
        ),
    ],
    swiftLanguageModes: [.v5]
)
