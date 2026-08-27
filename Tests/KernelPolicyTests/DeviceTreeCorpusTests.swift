//
//  DeviceTreeCorpusTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

import Testing
@testable import Kernel
import KernelTestSupport

/// The real FDT walk over the real blobs QEMU hands the kernel.
///
/// Every other device tree test in this package builds its input, which means it
/// can only ever contain what somebody thought to put in it. These three blobs
/// were dumped out of `qemu-system-aarch64` itself (see
/// `Tests/Fixtures/dtb/README.md`), so what is under test here is the walk
/// against a tree with 40-odd virtio nodes, a `cpu-map` five levels deep, a
/// `#address-cells` that changes under `/cpus`, and a megabyte of declared
/// padding behind `FDT_END`.
///
/// Each blob is staged in a mapping whose readable extent is exactly what its
/// header declares, with an unreadable page on each side and read-only
/// permissions on the blob itself, so a walk that stepped outside it or wrote
/// into it would fault rather than pass quietly. For an untouched dump the file
/// length and `totalsize` coincide at 1 MiB, so both guard pages sit flush.
///
/// This suite owns no kernel global: `getPlatformInfo` fills a caller's
/// `PlatformInfo` and reads only the two initrd linker symbols. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Device tree corpus")
struct DeviceTreeCorpusTests {

    /// The virt machine's layout, as QEMU has documented it for a decade: RAM at
    /// 1 GiB, the PL011 in the device window below it, and the GICv2
    /// distributor and CPU interface 64 KiB apart.
    enum VirtLayout {
        static let ramBase   : UInt64 = 0x4000_0000
        static let ram128M   : UInt64 = 0x0800_0000
        static let ram4M     : UInt64 = 0x0040_0000
        static let uartBase  : UInt64 = 0x0900_0000
        static let uartPL011 : UInt32 = 1
        static let gicdBase  : UInt64 = 0x0800_0000
        static let giccBase  : UInt64 = 0x0801_0000
        static let cpuCount  : UInt32 = 1

        /// `interrupts = <0x0 0x1 0x4>`: an SPI, so the walk adds the 32 lines
        /// the GIC keeps below the first shared peripheral.
        static let uartIRQ: UInt32 = 33

        /// The window the initrd capture declares, and the length of the
        /// `fake-initrd.bin` it was captured with.
        static let initrdStart: UInt64 = 0x4400_0000
        static let initrdEnd  : UInt64 = 0x4400_2000

        /// QEMU reserves a 1 MiB device tree window and declares all of it.
        static let declaredSize: UInt32 = 0x10_0000
    }


    @Test("every captured QEMU virt blob is accepted, console and all", arguments: FixtureCorpus.DeviceTree.all)
    func capturedBlobsAreAccepted(_ path: String) {
        guard let blob = FixtureCorpus.bytes(path) else {
            Issue.record("missing fixture \(path)")
            return
        }

        #expect(blob.count == 1 << 20)
        #expect(DeviceTreeBlob.totalSize(blob) == VirtLayout.declaredSize)

        let outcome = withStagedDeviceTree(blob) { base -> (fault: String?, info: PlatformInfo, base: UInt64) in
            var info  = PlatformInfo()
            let fault = getPlatformInfo(&info, at: base)

            return (fault.map { String(describing: $0.reason) }, info, UInt64(UInt(bitPattern: base)))
        }

        guard let outcome else {
            Issue.record("the guarded mapping for \(path) could not be made")
            return
        }

        #expect(outcome.fault == nil)
        #expect(outcome.info.dtbBase == outcome.base)
        #expect(outcome.info.dtbSize == VirtLayout.declaredSize)
        #expect(outcome.info.uart.baseAddr == VirtLayout.uartBase)
        #expect(outcome.info.uart.type     == VirtLayout.uartPL011)
        #expect(outcome.info.uart.irq      == VirtLayout.uartIRQ)
        #expect(outcome.info.gic.gicdBase  == VirtLayout.gicdBase)
        #expect(outcome.info.gic.giccBase  == VirtLayout.giccBase)
        #expect(outcome.info.cpuCount      == VirtLayout.cpuCount)
        #expect(outcome.info.ram.base      == VirtLayout.ramBase)
    }


    @Test("the 128M and 4M captures differ only in the size of the RAM region")
    func ramSizeIsTheOnlyDifference() {
        guard let big   = walk(FixtureCorpus.DeviceTree.virt128M),
              let small = walk(FixtureCorpus.DeviceTree.virt4M) else { return }

        #expect(big.ram.base   == VirtLayout.ramBase)
        #expect(small.ram.base == VirtLayout.ramBase)
        #expect(big.ram.size   == VirtLayout.ram128M)
        #expect(small.ram.size == VirtLayout.ram4M)

        // Everything the two captures share, so a future recapture that moved
        // the UART or the GIC shows up here and not as a mysterious boot hang.
        #expect(big.uart.baseAddr == small.uart.baseAddr)
        #expect(big.uart.type     == small.uart.type)
        #expect(big.uart.irq      == small.uart.irq)
        #expect(big.gic.gicdBase  == small.gic.gicdBase)
        #expect(big.gic.giccBase  == small.gic.giccBase)
        #expect(big.cpuCount      == small.cpuCount)
        #expect(big.dtbSize       == small.dtbSize)
    }


    @Test("the initrd capture reports the window /chosen declares, inside the declared RAM")
    func initrdWindowComesFromChosen() {
        guard let info = walk(FixtureCorpus.DeviceTree.virt128MInitrd) else { return }

        #expect(info.initrdStart == VirtLayout.initrdStart)
        #expect(info.initrdEnd   == VirtLayout.initrdEnd)
        #expect(info.initrdEnd - info.initrdStart == 8192)

        // The one region relation the blob states: an archive the allocator is
        // expected to withhold has to be in the memory that allocator owns.
        #expect(info.initrdStart >= info.ram.base)
        #expect(info.initrdEnd   <= info.ram.base + info.ram.size)
    }


    @Test("a capture taken without a kernel declares no initrd at all")
    func capturesWithoutAKernelDeclareNoInitrd() {
        // QEMU only fills /chosen from its image loader, so these two dumps
        // reach FDT_END with the two properties absent rather than empty.
        for path in [FixtureCorpus.DeviceTree.virt128M, FixtureCorpus.DeviceTree.virt4M] {
            guard let info = walk(path) else { continue }

            #expect(info.initrdStart == 0)
            #expect(info.initrdEnd   == 0)
        }
    }


    @Test("the walk reports the blob it was handed, at the address it was handed")
    func blobExtentIsReportedAsStaged() {
        guard let blob = FixtureCorpus.bytes(FixtureCorpus.DeviceTree.virt128M) else {
            Issue.record("missing fixture")
            return
        }

        // The live tree is 0x1d96 bytes of a blob that declares 0x100000, and
        // the declared figure is what the reclaim later hands back.
        #expect(DeviceTreeBlob.declaredReach(blob) == 0x1d96)

        let outcome = withStagedDeviceTree(blob) { base -> (UInt64, UInt64, UInt32) in
            var info = PlatformInfo()
            _ = parsePlatformInfo(fdt: base, into: &info)

            return (UInt64(UInt(bitPattern: base)), info.dtbBase, info.dtbSize)
        }

        guard let outcome else {
            Issue.record("the guarded mapping could not be made")
            return
        }

        #expect(outcome.1 == outcome.0)
        #expect(outcome.2 == VirtLayout.declaredSize)
    }


    // MARK: - Helpers

    /// What the FDT walk alone read out of a fixture, with no console gate and
    /// no fallback to the archive linked into the kernel image.
    ///
    /// `parsePlatformInfo` rather than `getPlatformInfo` wherever the initrd is
    /// the subject: the public entry point substitutes the image-linked window
    /// when the blob declares none, which is the behaviour a boot wants and the
    /// opposite of what a test asking "what does this blob say" wants.
    private func walk(_ path: String) -> PlatformInfo? {
        guard let blob = FixtureCorpus.bytes(path) else {
            Issue.record("missing fixture \(path)")
            return nil
        }

        let outcome = withStagedDeviceTree(blob) { base -> (String?, PlatformInfo) in
            var info  = PlatformInfo()
            let fault = parsePlatformInfo(fdt: base, into: &info)

            return (fault.map { String(describing: $0.reason) }, info)
        }

        guard let outcome else {
            Issue.record("the guarded mapping for \(path) could not be made")
            return nil
        }

        #expect(outcome.0 == nil)
        return outcome.1
    }
}

extension DeviceTreeCorpusTests {

    /// What the machine this actually runs on says its virtio bus is.
    ///
    /// The numbers are here so that a recapture which moved a transport, or a
    /// QEMU that started declaring them somewhere else, shows up as a failing
    /// assert rather than as a disk that is never found.
    ///
    /// They also record why the merged-range model survived as long as it did:
    /// thirty-two windows end to end with no hole, and lines that run alongside
    /// them one for one. Every assumption it made is true here, and none of them
    /// were ever properties of a device tree.
    private enum VirtBus {
        static let count : UInt32 = 32
        static let base  : UInt64 = 0x0A00_0000
        static let size  : UInt32 = 0x200
        static let line  : UInt32 = 48
    }


    @Test("the virtio bus comes back as the thirty-two transports the blob declares")
    func virtioTransportsAreExact() {
        guard let info = walk(FixtureCorpus.DeviceTree.virt128M) else { return }

        let bus = info.virtioBus

        #expect(bus.count    == VirtBus.count)
        #expect(bus.rejected == 0)
        #expect(bus.isPresent)
        #expect(bus.transport(at: VirtBus.count) == nil)

        for index in 0..<VirtBus.count {
            guard let transport = bus.transport(at: index) else {
                Issue.record("no transport at \(index)")
                return
            }

            #expect(transport.base == VirtBus.base + UInt64(index) * UInt64(VirtBus.size))
            #expect(transport.size == VirtBus.size)
            #expect(transport.line == VirtBus.line + index)
        }
    }


    /// Sorted, whichever order the blob listed its nodes in. The walk reads the
    /// tree in file order and nothing promises that is address order.
    @Test("the transports come back in address order, with no two overlapping")
    func virtioTransportsAreSortedAndDisjoint() {
        guard let info = walk(FixtureCorpus.DeviceTree.virt128M) else { return }

        let bus = info.virtioBus

        for index in 1..<bus.count {
            guard let previous = bus.transport(at: index - 1),
                  let current  = bus.transport(at: index)
            else {
                Issue.record("no transport at \(index)")
                return
            }

            #expect(previous.base < current.base)
            #expect(previous.end <= current.base)
            #expect(previous.line != current.line)
        }
    }


    @Test("the 4M capture describes the same bus as the 128M one")
    func virtioBusIsTheSameOnBothCaptures() {
        guard let big   = walk(FixtureCorpus.DeviceTree.virt128M),
              let small = walk(FixtureCorpus.DeviceTree.virt4M) else { return }

        #expect(big.virtioBus.count == small.virtioBus.count)

        for index in 0..<big.virtioBus.count {
            #expect(big.virtioBus.transport(at: index)?.base == small.virtioBus.transport(at: index)?.base)
            #expect(big.virtioBus.transport(at: index)?.line == small.virtioBus.transport(at: index)?.line)
        }
    }
}
