import PackagePlugin
import Foundation

// ReixOS bare-metal orchestrator.
//
// SPM compiles the Swift modules into static libraries (.a). This plugin does
// what SPM cannot: compile the native (.c/.S) sources with clang, link the
// kernel image with linker.ld and the userland ELFs with user.ld, run objcopy
// to produce kernel.bin, pack initrd.tar and (optionally) launch QEMU.
//
// Prerequisite: the .a files must already exist. Build them first with:
//     swift build --triple aarch64-none-none-elf
//

@main
struct ReixPlugin: CommandPlugin {

    let clang   = "/opt/homebrew/opt/llvm/bin/clang"
    let lld     = "/opt/homebrew/opt/lld@20/bin/ld.lld"
    let objcopy = "/opt/homebrew/opt/llvm/bin/llvm-objcopy"
    let qemu    = "/opt/homebrew/bin/qemu-system-aarch64"
    let tarTool = "/usr/bin/tar"

    let triple = "aarch64-none-none-elf"
    let apps = ["Init", "Child", "Child2", "NameServer", "ProcessServer", "ConsoleServer"]
    
    let kernelNative = [
        "Sources/ReixKernel/Arch/aarch64/Boot/boot.S",
        "Sources/ReixKernel/Arch/aarch64/ContextSwitch/ContextSwitch.S",
        "Sources/ReixKernel/Arch/aarch64/Exceptions/Handlers/ContextSaving.S",
    ]

    let reixNative = [
        "Native/reix/AsmSyscall.S",
    ]

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL
        let release = arguments.contains("--release")
        let doRun = arguments.contains("run")
        let config = release ? "release" : "debug"
        let buildDir = root.appending(path: ".build/\(triple)/\(config)")

        let mustExist = (["libKernel", "libReixABI", "libReix"] + apps.map { "lib\($0)" })
            .map { buildDir.appending(path: "\($0).a") }
        let missing = mustExist.filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            Diagnostics.error("""
            Missing libraries in \(buildDir.path):
            \(missing.map { "  - " + $0.lastPathComponent }.joined(separator: "\n"))
            Build the modules first:  swift build --triple \(triple)\(release ? " -c release" : "")
            """)
            return
        }

        func obj(_ src: String) -> URL { work.appending(path: (src as NSString).lastPathComponent + ".o") }

        let cFlags = ["-target", triple, "-ffreestanding", "-O2", "-nostdlib",
                      "-fno-stack-protector", "-ISources/ReixKernel/Platform/DeviceTree", "-g"]
        func compile(_ src: String) throws {
            let isAsm = src.hasSuffix(".S")
            let args = (isAsm ? ["-target", triple] : cFlags)
                + ["-c", root.appending(path: src).path, "-o", obj(src).path]
            try run(clang, args, cwd: root)
        }
        for s in kernelNative + reixNative { try compile(s) }
        print("✓ native compiled (\(kernelNative.count + reixNative.count) files)")

        var generatedObjs: [URL] = []
        for (name, source) in generatedKernelAsm() {
            let src = work.appending(path: name)
            try source.write(to: src, atomically: true, encoding: .utf8)
            let o = work.appending(path: name + ".o")
            try run(clang, ["-target", triple, "-c", src.path, "-o", o.path], cwd: root)
            generatedObjs.append(o)
        }
        print("✓ generated asm (\(generatedObjs.count) files)")

        var reixGeneratedObjs: [URL] = []
        for (name, source) in generatedUserlandAsm() {
            let src = work.appending(path: name)
            try source.write(to: src, atomically: true, encoding: .utf8)
            let o = work.appending(path: name + ".o")
            try run(clang, ["-target", triple, "-c", src.path, "-o", o.path], cwd: root)
            reixGeneratedObjs.append(o)
        }
        print("✓ generated userland asm (\(reixGeneratedObjs.count) files)")

        let kernelElf = root.appending(path: "kernel.elf")
        try run(lld, [
            "-T", root.appending(path: "linker.ld").path, "--nmagic",
            "-o", kernelElf.path,
        ] + kernelNative.map { obj($0).path } + generatedObjs.map { $0.path } + [
            "--start-group",
            buildDir.appending(path: "libKernel.a").path,
            buildDir.appending(path: "libReixABI.a").path,
            "--end-group",
        ], cwd: root)

        let kernelBin = root.appending(path: "kernel.bin")
        try run(objcopy, ["-O", "binary", kernelElf.path, kernelBin.path], cwd: root)
        print("✓ kernel.bin")

        let reixObjs = reixNative.map { obj($0).path } + reixGeneratedObjs.map { $0.path }
        for app in apps {
            try run(lld, [
                "-T", root.appending(path: "user.ld").path,
                "-o", root.appending(path: "\(app).elf").path,
            ] + reixObjs + [
                "--whole-archive", buildDir.appending(path: "lib\(app).a").path, "--no-whole-archive",
                "--start-group",
                buildDir.appending(path: "libReix.a").path,
                buildDir.appending(path: "libReixABI.a").path,
                "--end-group",
            ], cwd: root)
        }
        print("✓ \(apps.count) userland ELFs")

        try run(tarTool, ["-cf", root.appending(path: "initrd.tar").path,
                          "-C", root.path] + apps.map { "\($0).elf" }, cwd: root)
        print("✓ initrd.tar")

        if doRun {
            print("→ qemu (Ctrl-A X to quit)")
            try run(qemu, [
                "-machine", "virt,gic-version=2", "-cpu", "cortex-a53", "-nographic",
                "-kernel", kernelBin.path, "-initrd", root.appending(path: "initrd.tar").path,
            ], cwd: root, inheritIO: true)
        } else {
            print("To run:  swift package --allow-writing-to-package-directory reix run")
        }
    }

    /// Runs an external tool; throws on a non-zero exit code.
    func run(_ tool: String, _ args: [String], cwd: URL, inheritIO: Bool = false) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        var captured = Data()
        let pipe = Pipe()
        if !inheritIO { p.standardOutput = pipe; p.standardError = pipe }
        try p.run()
        if !inheritIO { captured = pipe.fileHandleForReading.readDataToEndOfFile() }
        p.waitUntilExit()
        
        if p.terminationStatus != 0 {
            let out = String(data: captured, encoding: .utf8) ?? ""
            throw ReixError.tool("\((tool as NSString).lastPathComponent) exit=\(p.terminationStatus)\n\(out)")
        }
    }
}

enum ReixError: Error, CustomStringConvertible {
    case tool(String)
    var description: String { switch self { case .tool(let m): return m } }
}
