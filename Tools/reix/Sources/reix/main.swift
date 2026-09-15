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

// REIX_BUILD_PATH is the plugin's spelling and the Makefile still speaks it, so
// a tree named by anything but the boot mode stays reachable.
let options = BuildPipeline.Options(
    release  : arguments.contains("--release"),
    bootMode : value(of: "--boot-mode")  ?? ProcessInfo.processInfo.environment["BOOT_MODE"] ?? "standard",
    buildPath: value(of: "--build-path") ?? ProcessInfo.processInfo.environment["REIX_BUILD_PATH"]
)

do {
    let pipeline = try BuildPipeline(root: root, options: options)

    // Task 7 swaps this for the dashboard when stdout is a terminal. Until then
    // a terminal gets the one line it can redraw, and a pipe gets the report.
    let interactive = isatty(FileHandle.standardOutput.fileDescriptor) == 1

    let sink = EventSink { event in
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

    let ok = await PhaseRunner.run(pipeline.steps(), into: sink)
    exit(ok ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
