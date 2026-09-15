//
//  QemuMachineTests.swift
//  ReixOS
//

import Testing
import Foundation
@testable import ReixBuild

/// The machine is still spelled out in three other places, and only one of them
/// can be checked from here: the Makefile's QEMU_FLAGS, which this reads off
/// disk and compares. scripts/smoke.sh and the Xcode scheme are not read, and
/// nothing below would notice them drifting.
///
/// The rest of the line is a snapshot of what `make -n run` and `make -n run-4m`
/// printed when this was written. That is a change detector, not a cross-check:
/// it catches QemuMachine moving, not the Makefile moving.
@Suite struct QemuMachineTests {

    let out = URL(fileURLWithPath: "/repo/.reix")

    /// The file itself, then Tools/reix/Tests/ReixBuildTests above it.
    var repositoryRoot: URL {
        (1...5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in
            url.deletingLastPathComponent()
        }
    }

    @Test func agreesWithTheMakefilesQemuFlags() throws {
        let makefile = try String(contentsOf: repositoryRoot.appending(path: "Makefile"),
                                  encoding: .utf8)

        let assignment = try #require(
            makefile.split(separator: "\n").first { $0.hasPrefix("QEMU_FLAGS") }
        )
        let declared = try #require(assignment.range(of: ":=")).upperBound
        let flags    = assignment[declared...].split(separator: " ").map(String.init)

        #expect(!flags.isEmpty)
        #expect(Array(QemuMachine.arguments(
            mem: nil, disk: nil, kernel: out.appending(path: "kernel.bin"), initrd: nil
        ).prefix(flags.count)) == flags)
    }

    @Test func matchesTheMakefilesRunLine() {
        #expect(QemuMachine.arguments(
            mem   : nil,
            disk  : out.appending(path: "disk.img"),
            kernel: out.appending(path: "kernel.bin"),
            initrd: out.appending(path: "initrd.tar")
        ) == [
            "-machine", "virt,gic-version=2",
            "-cpu", "cortex-a53,pmu=on",
            "-nographic",
            "-drive", "file=/repo/.reix/disk.img,if=none,format=raw,id=reixdisk",
            "-device", "virtio-blk-device,drive=reixdisk",
            "-kernel", "/repo/.reix/kernel.bin",
            "-initrd", "/repo/.reix/initrd.tar",
        ])
    }

    /// `make run-4m`: the floor the project targets. No -initrd is the load
    /// bearing half, see INITRD_MODE in the Makefile.
    @Test func matchesTheMakefilesRun4mLine() {
        #expect(QemuMachine.arguments(
            mem   : "4M",
            disk  : out.appending(path: "disk.img"),
            kernel: out.appending(path: "kernel.bin"),
            initrd: nil
        ) == [
            "-machine", "virt,gic-version=2",
            "-cpu", "cortex-a53,pmu=on",
            "-nographic",
            "-m", "4M",
            "-drive", "file=/repo/.reix/disk.img,if=none,format=raw,id=reixdisk",
            "-device", "virtio-blk-device,drive=reixdisk",
            "-kernel", "/repo/.reix/kernel.bin",
        ])
    }

    /// An empty MEM is how the Makefile spells "the machine default", and it
    /// reaches here as an empty string rather than as nothing.
    @Test func anEmptyMemoryKnobIsNotAnEmptyFlag() {
        let arguments = QemuMachine.arguments(
            mem: "", disk: nil, kernel: out.appending(path: "kernel.bin"), initrd: nil
        )
        #expect(!arguments.contains("-m"))
    }
}
