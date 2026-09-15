//
//  Toolchain.swift
//  ReixOS
//

import Foundation

/// Where the external tools are. Hard-coded paths, as the plugin had them, but
/// in one place and checked up front: a missing tool should be one clear line
/// before the build starts, not a failure four phases in.
public struct Toolchain: Sendable {
    public let swift   : String
    public let clang   : String
    public let lld     : String
    public let objcopy : String
    public let qemu    : String
    public let qemuImg : String

    public static func discover() throws -> Toolchain {
        let home = NSHomeDirectory()
        let swift = FileManager.default.isExecutableFile(atPath: home + "/.swiftly/bin/swift")
            ? home + "/.swiftly/bin/swift"
            : "/usr/bin/swift"

        let toolchain = Toolchain(
            swift  : ProcessInfo.processInfo.environment["SWIFT"] ?? swift,
            clang  : "/opt/homebrew/opt/llvm/bin/clang",
            lld    : "/opt/homebrew/opt/lld@20/bin/ld.lld",
            objcopy: "/opt/homebrew/opt/llvm/bin/llvm-objcopy",
            qemu   : "/opt/homebrew/bin/qemu-system-aarch64",
            qemuImg: "/opt/homebrew/bin/qemu-img"
        )

        let missing = [toolchain.swift, toolchain.clang, toolchain.lld, toolchain.objcopy]
            .filter { !FileManager.default.isExecutableFile(atPath: $0) }

        guard missing.isEmpty else {
            throw ReixError.tool("missing tools:\n" + missing.map { "  " + $0 }.joined(separator: "\n"))
        }
        return toolchain
    }
}
