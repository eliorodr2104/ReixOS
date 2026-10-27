//
//  main.swift
//  ReixOS
//

import Foundation
import ReixBuild

let arguments = Array(CommandLine.arguments.dropFirst())
let root      = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func value(of flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let usage = """
usage: reix <command> [options]

  build                 compile, link and pack the bootable image
    --release           optimized build
    --boot-mode <mode>  standard | verbose | diagnostic
    --build-path <path> SwiftPM scratch tree
    --no-compile        link and pack what is already built
    --plain             one line per phase, never the dashboard
    --verbose           --plain, and every byte every tool writes, on stderr

  run                   build, provision the disk, then boot it in QEMU
    --mem <size>        guest RAM, machine default when omitted
    --embedded-initrd   boot the copy linked into kernel.bin

  boot                  boot what is already built, compiling nothing

  app link <Name>       relink and strip one program, nothing else
  trace <logfile>       decode a serial trace dump
  symbolize [<report>]  resolve a panic report, clipboard when unnamed
  --help                this
"""

/// Every subcommand that is not the build reports its failure the same way: one
/// line on standard error and a non-zero exit, which is what the shell scripts
/// around this CLI test for.
func attempt(_ body: () throws -> Void) -> Never {
    do {
        try body()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

// REIX_BUILD_PATH is the plugin's spelling and the Makefile still speaks it, so
// a tree named by anything but the boot mode stays reachable.
let options = BuildPipeline.Options(
    release  : arguments.contains("--release"),
    bootMode : value(of: "--boot-mode")  ?? ProcessInfo.processInfo.environment["BOOT_MODE"] ?? "standard",
    buildPath: value(of: "--build-path") ?? ProcessInfo.processInfo.environment["REIX_BUILD_PATH"],
    verbose  : arguments.contains("--verbose"),
    compile  : !arguments.contains("--no-compile")
)

// A bare `reix` builds, which is the command this front end exists for. Every
// other verb is matched exactly: an unknown one is a typo, not a build request.
let verb = arguments.first ?? "build"

switch verb {
    case "--help", "-h", "help":
        print(usage)
        exit(0)

    // Reads a log file and prints a report, so it runs before any of the build
    // machinery: it needs no toolchain, no .a files and no output directory.
    case "trace":
        attempt { try TraceDecoder.run(arguments: arguments, root: root) }

    // Same reasoning as trace, plus it is the command a reader reaches for when
    // the build is the thing that just died.
    case "symbolize":
        attempt { try symbolize(root: root, arguments: arguments) }

    case "app":
        guard arguments.dropFirst().first == "link",
              let app = arguments.dropFirst(2).first(where: { !$0.hasPrefix("--") })
        else {
            FileHandle.standardError.write(Data("usage: reix app link <Name> [--release]\n".utf8))
            exit(1)
        }
        attempt {
            let linked = try BuildPipeline(root: root, options: options).linkApp(app)
            print("  linked      " + linked)
        }

    case "build", "run", "boot":
        break

    default:
        FileHandle.standardError.write(Data("reix: unknown command '\(verb)'\n\n\(usage)\n".utf8))
        exit(1)
}

do {
    let pipeline = try BuildPipeline(root: root, options: options)

    // A terminal gets the one line it can redraw, and a pipe gets the report.
    // The two lifeboat flags opt out of cursor control, not just the dashboard.
    let interactive = isatty(FileHandle.standardOutput.fileDescriptor) == 1
        && !arguments.contains("--plain")
        && !arguments.contains("--verbose")

    let sink = EventSink { event in
        // The tool's own lines belong to the log and to `--verbose`, which echoes
        // them on stderr. Nothing here, so this stdout stays what scripts parse.
        if case .output = event { return }

        if case .progress(let phase, let done, let total, let now) = event {
            guard interactive, total > 0 else { return }
            let label = phase.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("\u{1B}[2K\r  \(label)[\(done)/\(total)] \(now)", terminator: "")
            fflush(stdout)
            return
        }

        if interactive { print("\u{1B}[2K\r", terminator: "") }
        if let line = FlatRenderer.line(for: event) { print(line) }
    }

    // `boot` compiles nothing and installs nothing, which is what makes it the
    // second half of the one-program loop: `make app APP=Shell`, then this.
    let steps: [PhaseRunner.Step] = switch verb {
        case "boot": []
        case "run" : pipeline.steps() + [pipeline.programs]
        default    : pipeline.steps()
    }

    // Whoever is reading decides: a person at a terminal gets the dashboard,
    // anything that scrapes the output keeps the lines it already parses.
    let dashboard = interactive
        && !steps.isEmpty
        && ProcessInfo.processInfo.environment["CI"] == nil

    let ok = dashboard
        ? await Dashboard.run(steps, options: options, root: root)
        : await PhaseRunner.run(steps, into: sink)
    guard ok else { exit(1) }
    guard verb != "build" else { exit(0) }

    let out  = root.appending(path: ".reix")
    let live = out.appending(path: "disk.img.live")

    guard FileManager.default.fileExists(atPath: out.appending(path: "kernel.bin").path) else {
        FileHandle.standardError.write(Data("no .reix/kernel.bin: run `reix build` first\n".utf8))
        exit(1)
    }

    // The marker the offline installer refuses to write past. A running guest
    // owns the image, and two writers disagreeing about it is a corrupt disk.
    guard !FileManager.default.fileExists(atPath: live.path) else {
        FileHandle.standardError.write(Data("disk already in use: \(live.path)\n".utf8))
        exit(1)
    }
    FileManager.default.createFile(atPath: live.path, contents: nil)
    QemuMachine.releaseOnSignal(marker: live.path)
    defer { try? FileManager.default.removeItem(at: live) }

    let qemu = Process()
    qemu.executableURL       = URL(fileURLWithPath: try Toolchain.discover().qemu)
    qemu.currentDirectoryURL = root
    qemu.arguments = QemuMachine.arguments(
        mem   : value(of: "--mem"),
        disk  : out.appending(path: "disk.img"),
        kernel: out.appending(path: "kernel.bin"),
        initrd: arguments.contains("--embedded-initrd")
            ? nil
            : out.appending(path: "initrd.tar")
    )

    // The guest writes to this descriptor too, and a buffer nobody flushed would
    // land after everything it prints, or vanish entirely if a signal ends us.
    //
    // Nothing is announced here. The summary card is the last thing the build
    // says, and the guest's own banner is the next thing on screen.
    fflush(stdout)

    try qemu.run()
    QemuMachine.waitInForeground(qemu)
    try? FileManager.default.removeItem(at: live)

    // The normal exit. A signal takes the other path, in releaseOnSignal, which
    // is where the sequence and the reason for it live.
    print("\r\u{1B}[J\u{1B}[?2004l\u{1B}[<u", terminator: "")
    exit(qemu.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
