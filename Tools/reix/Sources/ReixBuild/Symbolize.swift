//
//  Symbolize.swift
//  ReixOS
//

import Foundation

/// Address resolution, shared by the `--profile` trace view and the `symbolize`
/// subcommand. Lifted verbatim out of the plugin; only the plugin diagnostics
/// changed.
let symbolizer: String = "/opt/homebrew/opt/llvm/bin/llvm-symbolizer"

let clipboard: String = "/usr/bin/pbpaste"

/// Where to look for `swift-demangle`, best first: the installed toolchain,
/// then swiftly's shim. Optional: without it the report still resolves, it
/// just names functions in their mangled spelling.
private let demanglers: [String] = [
    NSHomeDirectory() + "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift-demangle",
    "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift-demangle",
    NSHomeDirectory() + "/.swiftly/bin/swift-demangle",
]


/// The `symbolize` subcommand.
///
/// A panic report leaves the device as a list of bare addresses. It has to: the
/// kernel carries no symbol table, because its .symtab is ~52 KB and the 4 MB
/// target cannot spend that on names it never reads itself. So the report prints
/// Fuchsia symbolizer markup, `{{{bt:0:0x40081138}}}`, beside every raw address,
/// which costs nothing on device, and resolution happens here.
///
///     reix symbolize panic.txt                  # a captured log
///     reix symbolize                            # the clipboard
///
/// The clipboard is read directly. Under the plugin it needed
/// `--disable-sandbox`, because the plugin sandbox denied the pasteboard
/// lookup; a plain host process has no such sandbox. Still not stdin, which
/// stays free for a future pipe.
///
/// `.reix/kernel.elf` is the right input and is always available: only the
/// userland ELFs are stripped, and only the copies that go into the initrd.
public func symbolize(root: URL, arguments: [String]) throws {
    let elf = elfArgument(arguments)
        ?? root.appending(path: ".reix/kernel.elf")

    guard FileManager.default.fileExists(atPath: elf.path) else {
        throw ReixError.tool("""
        No kernel image at \(elf.path).
        Build it first, or point the subcommand somewhere else:
            reix symbolize --elf <path/to/kernel.elf>
        Point at a different llvm-symbolizer the same way:
            reix symbolize --symbolizer <path/to/llvm-symbolizer>
        """)
    }

    let report = try readReport(arguments, cwd: root)

    let markup  = try NSRegularExpression(pattern: #"\{\{\{bt:[0-9]+:0x([0-9a-fA-F]+)\}\}\}"#)
    let matches = markup.matches(in: report, range: NSRange(report.startIndex..., in: report))

    guard !matches.isEmpty else {
        print(report, terminator: "")
        FileHandle.standardError.write(Data(
            "warning: No {{{bt:N:0xADDR}}} markup found in the report.\n".utf8
        ))
        return
    }

    let source    = report as NSString
    var addresses: [String] = []

    for match in matches {
        let address = "0x" + source.substring(with: match.range(at: 1)).lowercased()

        if !addresses.contains(address) { addresses.append(address) }
    }

    let resolved = try resolve(addresses, using: resolvedSymbolizer(arguments), in: elf, cwd: root)

    // Back to front: every replacement invalidates the offsets of the matches
    // that follow it, and none of the ones that precede it.
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
            Could not read the clipboard (\(clipboard)). Name a file instead:
                reix symbolize panic.txt
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


/// Address to `function at file:line`, one `llvm-symbolizer` invocation for
/// the whole report.
///
/// `--functions=linkage` rather than `short` on purpose: `short` only consults
/// DWARF, so every hand-written assembly routine in the kernel (`trigger_trap`,
/// the context switch, the exception vectors, i.e. exactly the frames a panic
/// tends to land in) comes back as `??`. `linkage` falls back to the symbol
/// table and names them.
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

        // Inlining is aggressive in Embedded Swift, so the innermost frame is
        // often not the one the reader is looking for. Keep the chain.
        resolved[entry.address] = rendered.isEmpty
            ? "??"
            : rendered.joined(separator: " <- inlined in ")
    }

    return resolved
}


/// Which `llvm-symbolizer` to run: an explicit `--symbolizer` argument first,
/// then the Homebrew install every other native tool here assumes, falling
/// back to whatever `PATH` names when neither exists.
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

    FileHandle.standardError.write(Data(
        "warning: No swift-demangle found; function names stay mangled.\n".utf8
    ))

    return names
}


/// Foundation has no `which`, and `Process` needs an absolute path: it will not
/// search `PATH` on its own, so this is what makes the PATH fallback usable
/// rather than a guaranteed launch failure.
private func which(_ name: String) -> String? {
    let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")

    for dir in dirs {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }

    return nil
}


/// Runs a tool and hands back what it printed. Standard error is inherited
/// rather than piped, so a chatty tool cannot fill a pipe nobody is draining.
func capture(
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

    /// Source position when DWARF has one, otherwise the symbol plus the offset
    /// into it, which is all a hand-written assembly frame can give.
    func rendered(as name: String, at address: String) -> String {
        guard !file.isEmpty, line > 0 else {
            let value  = UInt64(address.dropFirst(2), radix: 16) ?? 0
            let offset = value >= start ? value - start : 0

            return "\(name)+0x\(String(offset, radix: 16))"
        }

        return "\(name) at \((file as NSString).lastPathComponent):\(line)"
    }
}
