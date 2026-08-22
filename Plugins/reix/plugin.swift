import PackagePlugin
import Foundation

/// ReixOS bare-metal orchestrator.
///
/// SPM compiles the Swift modules into static libraries (`.a`). This plugin does
/// what SPM cannot: compile the native `.c`/`.S` sources with clang, link the
/// kernel image with `linker.ld` and the userland ELFs with `user.ld`, run objcopy
/// to produce `kernel.bin`, pack `initrd.tar` and, optionally, launch QEMU.
///
/// Every artifact lands in `.reix/` at the package root: a command plugin can only
/// write inside the package directory, and a single hidden folder keeps the root
/// clean. The initrd is packed by `UstarWriter` from `.reix/stripped/` with bare
/// entry names (`Init.elf`), which is what the kernel's TarFileSystem looks up
/// at spawn time; it also page-aligns each member's data so the kernel can map
/// ELF segments straight out of the archive. That same archive is then
/// `.incbin`-ed into the kernel image under `.initrd`, so a boot that passes no
/// `-initrd` still finds it; see the `.initrd` section in `linker.ld` for why a
/// 4 MiB machine needs that.
///
/// Prerequisite: the `.a` files must already exist. Build them first with
/// `swift build --triple aarch64-none-none-elf`.
@main
struct ReixPlugin: CommandPlugin {

    let clang   = "/opt/homebrew/opt/llvm/bin/clang"
    let lld     = "/opt/homebrew/opt/lld@20/bin/ld.lld"
    let objcopy = "/opt/homebrew/opt/llvm/bin/llvm-objcopy"
    let qemu    = "/opt/homebrew/bin/qemu-system-aarch64"

    let triple = "aarch64-none-none-elf"
    let outputDir = ".reix"
    let apps = ["Init", "Child", "Child2", "NameServer", "ProcessServer", "ConsoleServer", "TerminalServer", "Top", "Shell", "Hello"]
    
    let kernelNative = [
        "Sources/ReixKernel/Arch/aarch64/Boot/boot.S",
        "Sources/ReixKernel/Arch/aarch64/ContextSwitch/ContextSwitch.S",
        "Sources/ReixKernel/Arch/aarch64/Exceptions/Handlers/ContextSaving.S",
    ]

    let reixNative = [
        "Native/reix/AsmSyscall.S",
    ]

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        // Not a build at all, so it runs before anything else: it never needs
        // the .a files, the output directory or write permission.
        if arguments.first == "symbolize" {
            try symbolize(root: context.package.directoryURL, arguments: arguments)
            return
        }

        // Same reasoning as symbolize: it only reads a log file and prints a
        // report, so it runs before any of the build machinery below.
        if arguments.first == "trace" {
            try TraceDecoder.run(arguments: arguments, root: context.package.directoryURL)
            return
        }

        let root = context.package.directoryURL
        let work = context.pluginWorkDirectoryURL
        let release = arguments.contains("--release")
        let doRun = arguments.contains("run")
        let config = release ? "release" : "debug"
        let buildDir = root.appending(path: ".build/\(triple)/\(config)")

        let out = root.appending(path: outputDir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let mustExist = (["libKernel", "libReixABI", "libReix", "libShellLanguage"] + apps.map { "lib\($0)" })
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

        let reixObjs = reixNative.map { obj($0).path } + reixGeneratedObjs.map { $0.path }
        for app in apps {
            try run(lld, [
                "-T", root.appending(path: "user.ld").path,

                // lld defaults maxPageSize to 64 KiB on AArch64 and aligns the
                // first section's file offset to it, which `user.ld` cannot
                // reach: its ALIGN(4096) governs virtual addresses only.
                "-z", "max-page-size=4096",

                "-o", out.appending(path: "\(app).elf").path,
            ] + reixObjs + [
                "--whole-archive", buildDir.appending(path: "lib\(app).a").path, "--no-whole-archive",
                "--start-group",
                buildDir.appending(path: "libReix.a").path,
                buildDir.appending(path: "libReixABI.a").path,
                buildDir.appending(path: "libShellLanguage.a").path,
                "--end-group",
            ], cwd: root)
        }
        print("✓ \(apps.count) userland ELFs")

        // The initrd stays resident for the whole boot, so it carries stripped
        // copies: Init.elf is 1.3 MB unstripped, of which 25 KB is PT_LOAD.
        let strippedDir = out.appending(path: "stripped")
        try FileManager.default.createDirectory(at: strippedDir, withIntermediateDirectories: true)
        for app in apps {
            // --strip-all, not --strip-debug: `.swift_ast` is not DWARF and is 67%
            // of the file. Safe, ElfParser reads only the header and program headers.
            try run(objcopy, ["--strip-all",
                              out.appending(path: "\(app).elf").path,
                              strippedDir.appending(path: "\(app).elf").path], cwd: root)
        }
        print("✓ \(apps.count) stripped for initrd")

        let initrd = out.appending(path: "initrd.tar")
        // Written by UstarWriter, not /usr/bin/tar: it page-aligns each
        // member's data, which the initrd page-sharing design depends on.
        let members = try apps.map {
            UstarWriter.Member(name: "\($0).elf",
                                data: try Data(contentsOf: strippedDir.appending(path: "\($0).elf")))
        }
        let archive = UstarWriter.write(members: members)
        guard UstarWriter.verifyPageAlignment(archive) else {
            throw ReixError.tool("initrd.tar: a member's data is not 4096-aligned")
        }
        try archive.write(to: initrd)
        print("✓ \(outputDir)/initrd.tar (\(archive.count) bytes)")

        // The archive goes into the kernel image too, which is why the link
        // below happens here and not before the userland ELFs were packed.
        // `linker.ld` brackets the section with _initrd_start/_initrd_end.
        let initrdAsm = work.appending(path: "Initrd.gen.S")
        try """
        // Generated by the reix plugin. See the .initrd section in linker.ld.
            .section .initrd, "a", %progbits
            .incbin "\(initrd.path)"
        """.write(to: initrdAsm, atomically: true, encoding: .utf8)
        let initrdObj = work.appending(path: "Initrd.gen.S.o")
        try run(clang, ["-target", triple, "-c", initrdAsm.path, "-o", initrdObj.path], cwd: root)
        print("✓ initrd embedded in the kernel image")

        let kernelElf = out.appending(path: "kernel.elf")
        try run(lld, [
            "-T", root.appending(path: "linker.ld").path, "--nmagic",
            "-o", kernelElf.path,
        ] + kernelNative.map { obj($0).path } + generatedObjs.map { $0.path } + [
            initrdObj.path,
            "--start-group",
            buildDir.appending(path: "libKernel.a").path,
            buildDir.appending(path: "libReixABI.a").path,
            "--end-group",
        ], cwd: root)

        let kernelBin = out.appending(path: "kernel.bin")
        try run(objcopy, ["-O", "binary", kernelElf.path, kernelBin.path], cwd: root)
        print("✓ \(outputDir)/kernel.bin")

        if doRun {
            // Keep these in sync with QEMU_FLAGS in the Makefile, with
            // scripts/smoke.sh and with the Xcode scheme.
            var qemuArgs = [
                "-machine", "virt,gic-version=2", "-cpu", "cortex-a53,pmu=on", "-nographic",
            ]
            if let mem = value(of: "--mem", in: arguments) { qemuArgs += ["-m", mem] }
            qemuArgs += ["-kernel", kernelBin.path]

            // Without -initrd the kernel falls back to the copy just linked in,
            // which is the only way a 4 MiB machine boots. See the Makefile.
            if !arguments.contains("--embedded-initrd") {
                qemuArgs += ["-initrd", initrd.path]
            }

            print("→ qemu (Ctrl-A X to quit)")
            try run(qemu, qemuArgs, cwd: root, inheritIO: true)
        } else {
            print("To run:  swift package --allow-writing-to-package-directory reix run")
        }
    }

    /// The word after `flag`, when the argument list carries one.
    func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
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


// MARK: - trace

/// The `trace` subcommand.
///
/// The kernel can dump its trace ring to the serial console: syscall
/// latencies, IPC blocks/wakes/transfers, preemption spans, boot phases,
/// PC samples and PMU-bracketed sections, each printed as a `[TRACE] `-prefixed
/// line between a `begin`/`end` marker. Decoding that into readable tables is
/// pure host-side text processing, so it lives entirely in `TraceDecoder.swift`
/// next to this dispatch line.
///
///     swift package reix trace panic.txt                       # summary report
///     swift package reix trace panic.txt --boot                # boot-phase timeline
///     swift package reix trace panic.txt --raw                 # one line per event
///     swift package reix trace panic.txt --profile             # sampling + PMU profile
///     swift package reix trace panic.txt --profile --symbolizer <path>
///
/// `--profile` resolves kernel and per-process addresses through the same
/// `llvm-symbolizer` machinery as `symbolize` below, against `.reix/kernel.elf`
/// and the unstripped `.reix/<Name>.elf` for each named process; it degrades
/// to raw addresses when either is unavailable.
///
/// See the doc comment atop `TraceDecoder.swift` for the exact wire format.


// MARK: - symbolize

/// The `symbolize` subcommand.
///
/// A panic report leaves the device as a list of bare addresses. It has to:
/// the kernel carries no symbol table, because its .symtab is ~52 KB and the
/// 4 MB target cannot spend that on names it never reads itself. So the report
/// prints Fuchsia symbolizer markup, `{{{bt:0:0x40081138}}}`, beside every
/// raw address, which costs nothing on device, and resolution happens here.
///
///     swift package reix symbolize panic.txt                  # a captured log
///     swift package --disable-sandbox reix symbolize          # the clipboard
///
/// Not stdin, which is the obvious spelling and is not available: SwiftPM
/// speaks its host-to-plugin protocol over the plugin process's own stdin and
/// stdout, so a read on descriptor 0 gets a bad file descriptor and takes the
/// plugin down with it. The clipboard is the closer fit for a pasted block, but
/// `pbpaste` needs the pasteboard server and the plugin sandbox denies the
/// lookup, hence the `--disable-sandbox` in the second form above.
///
/// `.reix/kernel.elf` is the right input and is always available: only the
/// userland ELFs are stripped, and only the copies that go into the initrd.
extension ReixPlugin {

    var symbolizer: String { "/opt/homebrew/opt/llvm/bin/llvm-symbolizer" }
    var clipboard : String { "/usr/bin/pbpaste" }

    /// Where to look for `swift-demangle`, best first: the installed
    /// toolchain, then swiftly's shim. Optional: without it the report still
    /// resolves, it just names functions in their mangled spelling.
    var demanglers: [String] {
        [
            NSHomeDirectory() + "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift-demangle",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift-demangle",
            NSHomeDirectory() + "/.swiftly/bin/swift-demangle",
        ]
    }


    func symbolize(root: URL, arguments: [String]) throws {
        let elf = elfArgument(arguments)
            ?? root.appending(path: outputDir).appending(path: "kernel.elf")

        guard FileManager.default.fileExists(atPath: elf.path) else {
            Diagnostics.error("""
            No kernel image at \(elf.path).
            Build it first, or point the subcommand somewhere else:
                swift package reix symbolize --elf <path/to/kernel.elf>
            Point at a different llvm-symbolizer the same way:
                swift package reix symbolize --symbolizer <path/to/llvm-symbolizer>
            """)
            return
        }

        let report = try readReport(arguments, cwd: root)

        let markup  = try NSRegularExpression(pattern: #"\{\{\{bt:[0-9]+:0x([0-9a-fA-F]+)\}\}\}"#)
        let matches = markup.matches(in: report, range: NSRange(report.startIndex..., in: report))

        guard !matches.isEmpty else {
            print(report, terminator: "")
            Diagnostics.warning("No {{{bt:N:0xADDR}}} markup found in the report.")
            return
        }

        let source    = report as NSString
        var addresses: [String] = []

        for match in matches {
            let address = "0x" + source.substring(with: match.range(at: 1)).lowercased()

            if !addresses.contains(address) { addresses.append(address) }
        }

        let resolved = try resolve(addresses, using: resolvedSymbolizer(arguments), in: elf, cwd: root)

        // Back to front: every replacement invalidates the offsets of the
        // matches that follow it, and none of the ones that precede it.
        var output = report
        for match in matches.reversed() {
            let address = "0x" + source.substring(with: match.range(at: 1)).lowercased()

            guard let name = resolved[address],
                  let range = Range(match.range, in: output)
            else { continue }

            output.replaceSubrange(range, with: name)
        }

        print(output, terminator: "")
    }


    /// Address to `function at file:line`, one `llvm-symbolizer` invocation
    /// for the whole report.
    ///
    /// `--functions=linkage` rather than `short` on purpose: `short` only
    /// consults DWARF, so every hand-written assembly routine in the kernel
    /// (`trigger_trap`, the context switch, the exception vectors, i.e. exactly
    /// the frames a panic tends to land in) comes back as `??`. `linkage`
    /// falls back to the symbol table and names them.
    /// Shared with `TraceDecoder`'s `--profile` view, which resolves plain
    /// addresses the same way rather than re-walking `PATH` on its own.
    func resolve(
        _ addresses: [String],
        using tool  : String,
        in elf      : URL,
        cwd         : URL
    ) throws -> [String: String] {

        let json = try capture(tool, [
            "--obj=" + elf.path,
            "--functions=linkage",
            "--output-style=JSON",
        ] + addresses, cwd: cwd)

        // One object per address, wrapped in an array only when there is more than
        // one: every real report, but not the one-frame case somebody will hand it.
        let parsed  = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        let records = (parsed as? [[String: Any]])
            ?? (parsed as? [String: Any]).map { [$0] }
            ?? []

        var addressed: [(address: String, frames: [Frame])] = []
        for record in records {
            let address = (record["Address"] as? String ?? "").lowercased()
            let symbols = record["Symbol"]  as? [[String: Any]] ?? []

            addressed.append((address, symbols.map(Frame.init)))
        }

        let names = demangle(addressed.flatMap(\.frames).map(\.function))

        var resolved: [String: String] = [:]
        var cursor   = 0

        for entry in addressed {
            var rendered: [String] = []

            for frame in entry.frames {
                rendered.append(frame.rendered(as: names[cursor], at: entry.address))
                cursor += 1
            }

            // Inlining is aggressive in Embedded Swift, so the innermost frame
            // is often not the one the reader is looking for. Keep the chain.
            resolved[entry.address] = rendered.isEmpty
                ? "??"
                : rendered.joined(separator: " <- inlined in ")
        }

        return resolved
    }


    /// One `swift-demangle` pass over every name in the report.
    ///
    /// It echoes anything it does not recognise, so assembly labels survive
    /// untouched and the result stays index-aligned with its input.
    private func demangle(_ names: [String]) -> [String] {
        let input = names.joined(separator: "\n") + "\n"

        for tool in demanglers {
            guard FileManager.default.isExecutableFile(atPath: tool),
                  let output = try? capture(
                        tool, ["--compact"],
                        cwd  : URL(fileURLWithPath: NSTemporaryDirectory()),
                        input: input
                  )
            else { continue }

            let demangled = output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

            guard demangled.count >= names.count else { continue }

            return Array(demangled[0..<names.count])
        }

        Diagnostics.warning("No swift-demangle found; function names stay mangled.")

        return names
    }


    /// The report itself: a file if one was named, the clipboard otherwise.
    private func readReport(_ arguments: [String], cwd: URL) throws -> String {
        var positional: String?
        var index      = 1 // arguments[0] is the subcommand

        while index < arguments.count {
            if arguments[index] == "--elf" || arguments[index] == "--symbolizer" {
                index += 2
                continue
            }

            positional = arguments[index]
            break
        }

        guard let positional else {
            do {
                return try capture(clipboard, [], cwd: cwd)
            } catch {
                throw ReixError.tool("""
                Could not read the clipboard: the plugin sandbox denies the
                pasteboard lookup. Either name a file:
                    swift package reix symbolize panic.txt
                or lift the sandbox for this one run:
                    swift package --disable-sandbox reix symbolize
                """)
            }
        }

        return try String(contentsOf: URL(fileURLWithPath: positional), encoding: .utf8)
    }


    private func elfArgument(_ arguments: [String]) -> URL? {
        guard let flag = arguments.firstIndex(of: "--elf"),
              flag + 1 < arguments.count
        else { return nil }

        return URL(fileURLWithPath: arguments[flag + 1])
    }


    /// Which `llvm-symbolizer` to run: an explicit `--symbolizer` argument
    /// first, then the Homebrew install every other native tool here
    /// assumes, falling back to whatever `PATH` names when neither exists.
    ///
    /// Shared with `TraceDecoder`'s `--profile` view for the same reason as
    /// `resolve` above.
    func resolvedSymbolizer(_ arguments: [String]) -> String {
        if let flag = arguments.firstIndex(of: "--symbolizer"),
           flag + 1 < arguments.count {
            return arguments[flag + 1]
        }

        if FileManager.default.isExecutableFile(atPath: symbolizer) {
            return symbolizer
        }

        return which("llvm-symbolizer") ?? "llvm-symbolizer"
    }


    /// Foundation has no `which`, and `Process` needs an absolute path: it
    /// will not search `PATH` on its own, so this is what makes the PATH
    /// fallback above actually usable rather than a guaranteed launch failure.
    private func which(_ name: String) -> String? {
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")

        for dir in dirs {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }

        return nil
    }


    /// Runs a tool and hands back what it printed.
    ///
    /// The build phases only ever need to know whether a tool succeeded, so
    /// `run` throws its output away; symbolizing needs to read it. Standard
    /// error is inherited rather than piped, so a chatty tool cannot fill a
    /// pipe nobody is draining and deadlock the plugin.
    private func capture(
        _ tool: String,
        _ args: [String],
        cwd   : URL,
        input : String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL       = URL(fileURLWithPath: tool)
        process.arguments           = args
        process.currentDirectoryURL = cwd

        let output = Pipe()
        process.standardOutput = output
        process.standardError  = FileHandle.standardError

        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }

        try process.run()

        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ReixError.tool(
                "\((tool as NSString).lastPathComponent) exit=\(process.terminationStatus)"
            )
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}


/// One entry of `llvm-symbolizer`'s JSON, reduced to what the report shows.
private struct Frame {
    let function : String
    let file     : String
    let line     : Int
    let start    : UInt64

    init(_ symbol: [String: Any]) {
        function = symbol["FunctionName"]  as? String ?? "??"
        file     = symbol["FileName"]      as? String ?? ""
        line     = symbol["Line"]          as? Int    ?? 0
        start    = UInt64((symbol["StartAddress"] as? String ?? "").dropFirst(2), radix: 16) ?? 0
    }

    /// Source position when DWARF has one, otherwise the symbol plus the
    /// offset into it, which is all a hand-written assembly frame can give,
    /// and still enough to find the instruction in a disassembly.
    func rendered(as name: String, at address: String) -> String {
        guard !file.isEmpty, line > 0 else {
            let value  = UInt64(address.dropFirst(2), radix: 16) ?? 0
            let offset = value >= start ? value - start : 0

            return "\(name)+0x\(String(offset, radix: 16))"
        }

        return "\(name) at \((file as NSString).lastPathComponent):\(line)"
    }
}
