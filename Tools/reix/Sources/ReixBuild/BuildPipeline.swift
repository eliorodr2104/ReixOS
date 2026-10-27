//
//  BuildPipeline.swift
//  ReixOS
//

import Foundation

/// Every byte every tool wrote, always, whether the build succeeded or not.
/// The dashboard curates the screen; this is what it curated away.
public final class BuildLog: @unchecked Sendable {
    private let handle: FileHandle
    private let echo  : Bool
    private let lock = NSLock()

    /// `echo` is `--verbose`: the same bytes, on standard error as they land.
    /// Standard error because standard output carries the report the scripts
    /// parse, and a lifeboat that capsizes the log-scrapers is not one.
    public init(at url: URL, echo: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle    = try FileHandle(forWritingTo: url)
        self.echo = echo
    }

    public func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: Data(text.utf8))
        if echo { FileHandle.standardError.write(Data(text.utf8)) }
    }
}


/// The six phases of a build, as steps the engine can run.
///
/// This is the plugin's `performCommand`, rearranged: the work is identical and
/// the gate that says so is the sha256 of kernel.bin and initrd.tar. What
/// changed is that each phase now says what it is about to do before doing it,
/// and that the compile the Makefile used to run is now phase two rather than a
/// prerequisite the plugin could only check for.
///
/// Every artifact lands in `.reix/` at the package root, object files included:
/// the plugin wrote those into SwiftPM's sandboxed work directory, which no
/// longer exists, so `.reix/objects/` takes its place.
public struct BuildPipeline: Sendable {

    public struct Options: Sendable {
        public var release  : Bool
        public var bootMode : String
        public var buildPath: String
        public var verbose  : Bool

        /// False links and packs whatever is already in `buildPath`. The probe
        /// harnesses need it: they doctor a static archive we must not rebuild.
        public var compile  : Bool

        public init(
            release  : Bool = false,
            bootMode : String = "standard",
            buildPath: String? = nil,
            verbose  : Bool = false,
            compile  : Bool = true
        ) {
            self.release   = release
            self.bootMode  = bootMode
            self.buildPath = buildPath ?? ".build-freestanding-\(bootMode)"
            self.verbose   = verbose
            self.compile   = compile
        }
    }

    static let triple    = "aarch64-none-none-elf"
    static let outputDir = ".reix"
    static let diskSize  = "16M"

    static let apps = [
        "Init",
        "NameServer",
        "ConsoleServer",
        "SerialServer",
        "InputServer",
        "VTAdapter",
        "Top",
        "Shell",
        "VirtioBus",
        "BlockServer",
        "FileSystemServer",
        "StorageCheck",
        "ProcessServer",
    ]

    /// Ordinary programs are linked and stripped beside the image, outside the
    /// bootstrap archive. `reix app install` provisions these into RxFS before
    /// QEMU opens the disk.
    static let diskApps = ["Shell", "Top"]

    static let kernelNative = [
        "Native/kernel/KernelRuntimeABI.c",
        "Sources/ReixKernel/Arch/aarch64/Boot/boot.S",
        "Sources/ReixKernel/Arch/aarch64/ContextSwitch/ContextSwitch.S",
        "Sources/ReixKernel/Arch/aarch64/Exceptions/Handlers/ContextSaving.S",
    ]

    static let reixNative = [
        "Native/reix/UserRuntimeABI.c",
        "Native/reix/AsmSyscall.S",
    ]

    let root     : URL
    let options  : Options
    let toolchain: Toolchain
    let log      : BuildLog

    public init(root: URL, options: Options) throws {
        guard ["standard", "verbose", "diagnostic"].contains(options.bootMode) else {
            throw ReixError.tool(
                "BOOT_MODE must be standard, verbose or diagnostic, got '\(options.bootMode)'"
            )
        }

        self.root      = root
        self.options   = options
        self.toolchain = try Toolchain.discover()
        // `--verbose` echoes exactly what the log receives, so the two cannot
        // disagree. `stream` is line live, `run` echoes when its tool finishes.
        self.log = try BuildLog(
            at  : root.appending(path: Self.outputDir + "/build.log"),
            echo: options.verbose
        )
    }

    public func steps() -> [PhaseRunner.Step] {
        [prune] + (options.compile ? [compile] : []) + [native, userland, image, disk]
    }


    // MARK: - Where things live

    var out      : URL { root.appending(path: Self.outputDir) }
    var work     : URL { out.appending(path: "objects") }
    var stripped : URL { out.appending(path: "stripped") }
    var diskImage: URL { out.appending(path: "disk.img") }

    var buildDir: URL {
        root.appending(path: "\(options.buildPath)/\(Self.triple)/\(options.release ? "release" : "debug")")
    }

    /// The two probe knobs the plugin read from the environment. Separate from
    /// BOOT_MODE on purpose: they add sources, where BOOT_MODE only adds output.
    var fpsimdDiagnostic: Bool {
        ProcessInfo.processInfo.environment["REIX_FPSIMD_DIAGNOSTIC"] == "1"
    }

    var runtimeDiagnostic: Bool {
        ProcessInfo.processInfo.environment["REIX_RUNTIME_DIAGNOSTIC"] == "1"
            || ProcessInfo.processInfo.environment["REIX_RUNTIME_STACK_DIAGNOSTIC"] == "1"
    }

    var activeKernelNative: [String] {
        Self.kernelNative
            + (fpsimdDiagnostic ? ["Tests/GuestProbes/FPContextNested.S"] : [])
            + (runtimeDiagnostic ? ["Tests/GuestProbes/KernelRuntimeProbe.c"] : [])
    }

    /// Object paths are a function of the source list and nothing else, which is
    /// what lets a later phase link what an earlier one compiled without state.
    func object(_ source: String) -> URL {
        work.appending(path: (source as NSString).lastPathComponent + ".o")
    }

    var generatedKernelObjects  : [URL] { generatedKernelAsm().map   { work.appending(path: $0.name + ".o") } }
    var generatedUserlandObjects: [URL] { generatedUserlandAsm().map { work.appending(path: $0.name + ".o") } }


    // MARK: - The phases

    var prune: PhaseRunner.Step {
        .init(phase: .prune, why: "objects whose source is gone") { sink in
            // The script's exit code is not a build failure: it reports what it
            // found for a human, and finding nothing is the normal case.
            try run("/bin/sh", ["scripts/prune-stale.sh"], checkExit: false,
                    tail: tail(sink, .prune))
            return .done("stale objects checked")
        }
    }


    var compile: PhaseRunner.Step {
        .init(
            phase: .compile,
            why  : "\(Self.triple) · BOOT_MODE=\(options.bootMode)\(options.release ? " · release" : "")"
        ) { sink in
            var tracker = ProgressTracker()
            let clock   = ContinuousClock()

            // The names SwiftPM said it was compiling, not its `[n/m]` total: that
            // total counts llbuild tasks, of which a module is several.
            var modules = Set<String>()

            try stream(
                toolchain.swift,
                ["build", "--triple", Self.triple,
                 "--scratch-path", options.buildPath]
                    + (options.release ? ["-c", "release"] : []),
                environment: ["FREESTANDING": "1", "BOOT_MODE": options.bootMode],
                tail: tail(sink, .compile)
            ) { line in
                switch tracker.ingest(line, at: clock.now) {
                    case .bar(let done, let total, let detail):
                        if let module = Self.compiling(detail) { modules.insert(module) }
                        sink(.progress(.compile, done: done, total: total, now: detail))
                    case .spinner(let last):
                        sink(.progress(.compile, done: 0, total: 0, now: last))
                }
            }

            // A tree with nothing to do prints no `Compiling` line at all, which is
            // not the same as having compiled zero modules out of some total.
            return .done(modules.isEmpty ? "nothing to rebuild" : "\(modules.count) modules")
        }
    }

    var native: PhaseRunner.Step {
        .init(
            phase: .native,
            why  : "clang · \(activeKernelNative.count + Self.reixNative.count) sources and the generated assembly"
        ) { sink in
            try requireLibraries()
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let cFlags = ["-target", Self.triple, "-ffreestanding", "-O2", "-nostdlib",
                          "-fno-stack-protector", "-ISources/ReixKernel/Platform/DeviceTree", "-g"]

            func compileSource(_ src: String) throws {
                let isAsm = src.hasSuffix(".S")
                let diagnosticCFlags = src.hasSuffix("KernelRuntimeProbe.c")
                    ? ["-fstack-protector-all"]
                    : []
                let args = (isAsm
                    ? ["-target", Self.triple] + (fpsimdDiagnostic ? ["-DREIX_FPSIMD_DIAGNOSTIC"] : [])
                    : cFlags + diagnosticCFlags)
                    + ["-c", root.appending(path: src).path, "-o", object(src).path]
                try run(toolchain.clang, args, tail: tail(sink, .native))
            }

            let sources   = activeKernelNative + Self.reixNative
            let generated = generatedKernelAsm() + generatedUserlandAsm()
            let total     = sources.count + generated.count
            var done      = 0

            for source in sources {
                sink(.progress(.native, done: done, total: total,
                               now: (source as NSString).lastPathComponent))
                try compileSource(source)
                done += 1
            }

            for (name, source) in generated {
                sink(.progress(.native, done: done, total: total, now: name))
                let assembly = work.appending(path: name)
                try source.write(to: assembly, atomically: true, encoding: .utf8)
                try run(toolchain.clang, ["-target", Self.triple,
                                          "-c", assembly.path,
                                          "-o", work.appending(path: name + ".o").path],
                        tail: tail(sink, .native))
                done += 1
            }

            return .done("\(total) objects")
        }
    }

    var userland: PhaseRunner.Step {
        .init(
            phase: .userland,
            why  : "ld.lld and llvm-objcopy · \(Self.apps.count) programs"
        ) { sink in
            // The initrd stays resident for the whole boot, so it carries stripped
            // copies: Init.elf is 1.3 MB unstripped, of which 25 KB is PT_LOAD.
            try FileManager.default.createDirectory(at: stripped, withIntermediateDirectories: true)

            let reixObjects = Self.reixNative.map { object($0).path }
                + generatedUserlandObjects.map(\.path)

            for (index, app) in Self.apps.enumerated() {
                sink(.progress(.userland, done: index, total: Self.apps.count, now: app))

                try run(toolchain.lld, [
                    "-T", root.appending(path: "user.ld").path,

                    // lld defaults maxPageSize to 64 KiB on AArch64 and aligns the first
                    // section's file offset to it; user.ld's ALIGN(4096) is virtual only.
                    "-z", "max-page-size=4096",
                    "--gc-sections",

                    "-o", out.appending(path: "\(app).elf").path,
                ] + reixObjects + [
                    "--whole-archive", buildDir.appending(path: "lib\(app).a").path, "--no-whole-archive",
                    "--start-group",
                    buildDir.appending(path: "libReix.a").path,
                    buildDir.appending(path: "libReixABI.a").path,
                    buildDir.appending(path: "libShellLanguage.a").path,
                    buildDir.appending(path: "libProcessServerCore.a").path,
                    "--end-group",
                ], tail: tail(sink, .userland))

                // --strip-all, not --strip-debug: `.swift_ast` is not DWARF and is 67%
                // of the file. Safe, ElfParser reads the header and program headers.
                try run(toolchain.objcopy, ["--strip-all",
                                            out.appending(path: "\(app).elf").path,
                                            stripped.appending(path: "\(app).elf").path],
                        tail: tail(sink, .userland))
            }

            return .done("\(Self.apps.count) programs")
        }
    }

    var image: PhaseRunner.Step {
        .init(phase: .image, why: "initrd.tar, then kernel.elf and kernel.bin") { sink in
            let initrd = out.appending(path: "initrd.tar")

            // Written by UstarWriter, not /usr/bin/tar: it page-aligns each member's
            // data, which the initrd page-sharing design depends on.
            let initrdApps = Self.apps.filter { !Self.diskApps.contains($0) }
            let members    = try initrdApps.map {
                UstarWriter.Member(name: "\($0).elf",
                                   data: try Data(contentsOf: stripped.appending(path: "\($0).elf")))
            }
            let archive = UstarWriter.write(members: members)
            guard UstarWriter.verifyPageAlignment(archive) else {
                throw ReixError.tool("initrd.tar: a member's data is not 4096-aligned")
            }
            try archive.write(to: initrd)
            sink(.progress(.image, done: 1, total: 3, now: "initrd.tar"))

            // The archive goes into the kernel image too, which is why the link below
            // happens here; linker.ld brackets it with _initrd_start/_initrd_end.
            let initrdAsm = work.appending(path: "Initrd.gen.S")
            try """
            // Generated by the reix plugin. See the .initrd section in linker.ld.
                .section .initrd, "a", %progbits
                .incbin "\(initrd.path)"
            """.write(to: initrdAsm, atomically: true, encoding: .utf8)
            let initrdObj = work.appending(path: "Initrd.gen.S.o")
            try run(toolchain.clang, ["-target", Self.triple,
                                      "-c", initrdAsm.path, "-o", initrdObj.path],
                    tail: tail(sink, .image))

            let kernelElf = out.appending(path: "kernel.elf")
            sink(.progress(.image, done: 2, total: 3, now: "kernel.elf"))
            try run(toolchain.lld, [
                "-T", root.appending(path: "linker.ld").path, "--nmagic",
                "-o", kernelElf.path,
            ] + activeKernelNative.map { object($0).path } + generatedKernelObjects.map(\.path) + [
                initrdObj.path,
                "--start-group",
                buildDir.appending(path: "libKernel.a").path,
                buildDir.appending(path: "libReixABI.a").path,
                "--end-group",
            ], tail: tail(sink, .image))

            let kernelBin = out.appending(path: "kernel.bin")
            sink(.progress(.image, done: 3, total: 3, now: "kernel.bin"))
            try run(toolchain.objcopy, ["-O", "binary", kernelElf.path, kernelBin.path],
                    tail: tail(sink, .image))

            let imageBytes = (try? Data(contentsOf: kernelBin).count) ?? 0
            return .done("kernel \(size(imageBytes)) · initrd \(size(archive.count))")
        }
    }

    /// Created when missing and never migrated, so a volume formatted by one
    /// boot is mounted by the next. Provisioning programs into it is a separate
    /// command and stays that way: it runs the guest's own file system code.
    var disk: PhaseRunner.Step {
        .init(phase: .disk, why: "\(Self.diskSize) raw image at \(Self.outputDir)/disk.img") { sink in
            guard !FileManager.default.fileExists(atPath: diskImage.path) else {
                return .skipped("\(Self.outputDir)/disk.img is already there")
            }
            try run(toolchain.qemuImg, ["create", "-f", "raw", diskImage.path, Self.diskSize],
                    tail: tail(sink, .disk))
            return .done("\(Self.diskSize) raw image created")
        }
    }


    /// Provisions the ordinary programs into RxFS, which a boot needs and an
    /// image does not: `reix build` stops at `disk`, `reix run` adds this.
    ///
    /// Deliberately offline, and it is the guest's own file system code that
    /// runs here. FREESTANDING has to be cleared rather than merely unset:
    /// `ReixApp` is a host product, and Package.swift drops the host targets
    /// from the graph whenever the variable says 1.
    public var programs: PhaseRunner.Step {
        .init(phase: .programs, why: "\(Self.diskApps.joined(separator: " and ")) into \(Self.outputDir)/disk.img") { sink in
            try run(toolchain.swift, ["run", "ReixApp", "install", "--format-if-blank",
                                      "--disk", diskImage.path]
                + Self.diskApps.map { stripped.appending(path: "\($0).elf").path },
                environment: ["FREESTANDING": ""], tail: tail(sink, .programs))
            return .done("\(Self.diskApps.count) programs installed")
        }
    }


    // MARK: - The one-program loop

    /// Link and strip exactly one already-compiled application.
    ///
    /// Not a phase, and deliberately outside `steps()`: it never opens kernel.bin
    /// or initrd.tar, which is what makes their unchanged hashes a mechanical
    /// release gate rather than a promise. The `app-` and `App.` prefixes keep
    /// its objects apart from the full build's in the shared `.reix/objects`.
    @discardableResult
    public func linkApp(_ app: String) throws -> String {
        guard Self.apps.contains(app) else {
            throw ReixError.tool("usage: reix app link <\(Self.apps.joined(separator: "|"))> [--release]")
        }

        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stripped, withIntermediateDirectories: true)

        var libraries = ["lib\(app)", "libReix", "libReixABI"]
        if app == "Shell"         { libraries.append("libShellLanguage") }
        if app == "ProcessServer" { libraries.append("libProcessServerCore") }

        let missing = libraries
            .map { buildDir.appending(path: "\($0).a") }
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw ReixError.tool(
                "missing app libraries: \(missing.map(\.lastPathComponent).joined(separator: ", "))"
            )
        }

        func appObject(_ source: String) -> URL {
            work.appending(path: "app-" + (source as NSString).lastPathComponent + ".o")
        }

        for source in Self.reixNative {
            let nativeFlags = source.hasSuffix(".c")
                ? ["-target", Self.triple, "-ffreestanding", "-O2", "-nostdlib",
                   "-fno-stack-protector", "-ISources/ReixKernel/Platform/DeviceTree", "-g"]
                : ["-target", Self.triple]
            try run(toolchain.clang, nativeFlags + [
                "-c", root.appending(path: source).path,
                "-o", appObject(source).path,
            ])
        }

        var generated: [URL] = []
        for (name, source) in generatedUserlandAsm() {
            let assembly = work.appending(path: "App." + name)
            try source.write(to: assembly, atomically: true, encoding: .utf8)
            let output = work.appending(path: "App." + name + ".o")
            try run(toolchain.clang, ["-target", Self.triple,
                                      "-c", assembly.path, "-o", output.path])
            generated.append(output)
        }

        let elf              = out.appending(path: "\(app).elf")
        let groupedLibraries = libraries.map { buildDir.appending(path: "\($0).a").path }
        var linkArguments    = [
            "-T", root.appending(path: "user.ld").path,
            "-z", "max-page-size=4096",
            "--gc-sections",
            "-o", elf.path,
        ]
        linkArguments.append(contentsOf: Self.reixNative.map { appObject($0).path })
        linkArguments.append(contentsOf: generated.map(\.path))
        linkArguments.append(contentsOf: [
            "--whole-archive", buildDir.appending(path: "lib\(app).a").path,
            "--no-whole-archive", "--start-group",
        ])
        linkArguments.append(contentsOf: groupedLibraries.dropFirst())
        linkArguments.append("--end-group")
        try run(toolchain.lld, linkArguments)

        try run(toolchain.objcopy, ["--strip-all", elf.path,
                                    stripped.appending(path: "\(app).elf").path])
        return "\(app).elf"
    }


    // MARK: - What the phases are made of

    /// The `.a` files the links consume. The compile phase produces them, so a
    /// gap here means the module graph moved under the build, not a stale tree.
    func requireLibraries() throws {
        let names = ["libKernel", "libReixABI", "libReix", "libShellLanguage", "libProcessServerCore"]
            + Self.apps.map { "lib\($0)" }

        let missing = names
            .map { buildDir.appending(path: "\($0).a") }
            .filter { !FileManager.default.fileExists(atPath: $0.path) }

        guard missing.isEmpty else {
            throw ReixError.tool("""
            Missing libraries in \(buildDir.path):
            \(missing.map { "  - " + $0.lastPathComponent }.joined(separator: "\n"))
            """)
        }
    }


    /// The module named by `Compiling <Module> <File>.swift`, and nothing from
    /// the archiving, wrapping and file-list lines that share its counter.
    static func compiling(_ detail: String) -> String? {
        let prefix = "Compiling "

        guard detail.hasPrefix(prefix) else { return nil }
        return detail.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
    }

    /// Bytes as a terminal-width quantity, which is what a reader wants to
    /// compare between two builds.
    func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : "\((bytes + 512) / 1024) KiB"
    }

    /// A phase's line tap, for the dashboard's live tail. A closure and not the
    /// sink itself: `run` has no phase of its own, and `linkApp` has no sink.
    func tail(_ sink: EventSink, _ phase: Phase) -> (String) -> Void {
        { sink(.output(phase, line: $0)) }
    }

    /// Runs an external tool and appends everything it wrote to `.reix/build.log`.
    /// Throws on a non-zero exit code, carrying the tool's own output.
    @discardableResult
    func run(
        _ tool     : String,
        _ args     : [String],
        checkExit  : Bool = true,
        environment: [String: String] = [:],
        tail       : ((String) -> Void)? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL       = URL(fileURLWithPath: tool)
        process.arguments           = args
        process.currentDirectoryURL = root
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        try process.run()
        let captured = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: captured, encoding: .utf8) ?? ""
        log.write("$ \(tool) \(args.joined(separator: " "))\n" + output)

        // Buffered, not line live: `readDataToEndOfFile` above waits for the tool
        // to finish, so the tail gets these in one burst. These tools are brief.
        if let tail { for line in output.split(separator: "\n") { tail(String(line)) } }

        guard !checkExit || process.terminationStatus == 0 else {
            throw ReixError.tool(
                "\((tool as NSString).lastPathComponent) exit=\(process.terminationStatus)\n\(output)"
            )
        }
        return process.terminationStatus
    }

    /// `run` for the one tool whose output is worth reading as it arrives.
    ///
    /// Line by line rather than in one gulp at the end, because a compile is the
    /// phase long enough for silence to be indistinguishable from a hang. Every
    /// line still reaches the log, and a failure carries the whole transcript.
    func stream(
        _ tool     : String,
        _ args     : [String],
        environment: [String: String],
        tail       : ((String) -> Void)? = nil,
        onLine     : (String) -> Void
    ) throws {
        let process = Process()
        process.executableURL       = URL(fileURLWithPath: tool)
        process.arguments           = args
        process.currentDirectoryURL = root
        process.environment         = ProcessInfo.processInfo.environment
            .merging(environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        log.write("$ \(tool) \(args.joined(separator: " "))\n")
        try process.run()

        var transcript = ""
        func take(_ line: String) {
            transcript += line + "\n"
            log.write(line + "\n")
            tail?(line)
            onLine(line)
        }

        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                take(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer = Data(buffer[buffer.index(after: newline)...])
            }
        }
        if !buffer.isEmpty { take(String(decoding: buffer, as: UTF8.self)) }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ReixError.tool(
                "\((tool as NSString).lastPathComponent) exit=\(process.terminationStatus)\n\(transcript)"
            )
        }
    }
}
