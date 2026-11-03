//
//  ZeroBlockTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// When the kernel's memset zeroes with `dc zva`, decided by DCZID_EL0 as boot
/// read it, and how a range is split between whole blocks and the fill.
///
/// Every wrong answer here is a fault on some machine and silence on QEMU: a
/// `dc zva` with the MMU off is an alignment fault, one past either end of the
/// range zeroes a neighbour's bytes, and one under DZP is undefined.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder, DCZID_EL0,
/// the MMU switch and the loaded block size are all globals.
@Suite("Zero blocks", .serialized)
struct ZeroBlockTests {

    private static let guardBytes = 64
    private static let guardValue: UInt8 = 0xA5

    /// Loads `dczid` the way boot does, runs `body`, and puts every global back.
    private func withZeroIdentification(_ dczid: UInt64, mmu: Bool, _ body: () -> Void) {
        let saved      = Arch.MMU.cacheType
        let savedClean = Arch.MMU.cleanCacheNeedsInvalidate

        host_set_dczid(dczid)
        host_set_mmu_enabled(mmu ? 1 : 0)
        Arch.MMU.loadCacheType()
        mmu_trace_reset(nil)
        defer {
            mmu_trace_reset(nil)
            Arch.MMU.cacheType = saved
            Arch.MMU.cleanCacheNeedsInvalidate = savedClean
            Arch.MMU.zeroBlockBytes = 0
            host_set_mmu_enabled(0)
            host_set_dczid(0)
        }
        body()
    }

    /// A page-aligned buffer of `guardValue` with `count` bytes at `offset`
    /// zeroed through `kernelMemset`. Returns the range and whether it and the
    /// guards either side hold what they should.
    private func zero(
        offset: Int,
        count : Int,
        byte  : Int32 = 0
    ) -> (start: UInt, end: UInt, intact: Bool) {
        let total  = Self.guardBytes + offset + count + Self.guardBytes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 4096)
        defer { buffer.deallocate() }

        var index = 0
        while index < total { buffer.storeBytes(of: Self.guardValue, toByteOffset: index, as: UInt8.self); index += 1 }

        let start = buffer + Self.guardBytes + offset
        _ = kernelMemset(start, byte, UInt(count))

        var intact = true
        index = 0
        while index < total {
            let inside = index >= Self.guardBytes + offset && index < Self.guardBytes + offset + count
            let want   = inside ? UInt8(truncatingIfNeeded: byte) : Self.guardValue
            if buffer.load(fromByteOffset: index, as: UInt8.self) != want { intact = false }
            index += 1
        }

        return (UInt(bitPattern: start), UInt(bitPattern: start) + UInt(count), intact)
    }


    @Test("DCZID_EL0 decodes to its block size, or to never")
    func dczidDecodesToTheBlockOrToNever() {
        let rows: [(dczid: UInt64, block: Int)] = [
            (0x4, 64), (0x3, 32), (0x2, 16), (0x9, 2048),
            (0x1, 0), (0x0, 0), (0xA, 0), (0x14, 0), (0x10, 0),
        ]
        for row in rows {
            withZeroIdentification(row.dczid, mmu: true) {
                #expect(Arch.MMU.zeroBlockBytes == row.block, "DCZID 0x\(String(row.dczid, radix: 16))")
            }
        }
    }

    @Test("whole blocks go to dc zva, the edges to the fill")
    func wholeBlocksGoToDcZvaAndTheEdgesToTheFill() {
        withZeroIdentification(0x4, mmu: true) {
            for offset in [0, 1, 15, 16, 63, 64, 65, 127] {
                for count in [255, 256, 257, 320, 4096, 4097, 8191] {
                    mmu_trace_reset(nil)
                    let range = zero(offset: offset, count: count)
                    let calls = mmuCalls()
                    let label = "offset \(offset) count \(count)"

                    #expect(range.intact, "\(label)")
                    guard count >= 256 else {
                        #expect(calls.isEmpty, "\(label)")
                        continue
                    }

                    let first = (range.start + 63) & ~63
                    let last  = range.end & ~63
                    #expect(calls.count == 1, "\(label)")
                    #expect(calls.first?.op == .zeroBlocks, "\(label)")
                    #expect(calls.first?.arg == UInt64(first), "\(label)")
                    #expect(calls.first.map { $0.arg + $0.size } == UInt64(last), "\(label)")
                    #expect(calls.first?.line == 64, "\(label)")
                }
            }
        }
    }

    @Test("no dc zva with the MMU off")
    func noDcZvaWithTheMMUOff() {
        withZeroIdentification(0x4, mmu: false) {
            let range = zero(offset: 0, count: 4096)
            #expect(range.intact)
            #expect(mmuCalls().isEmpty)
        }
    }

    @Test("no dc zva for a fill that is not zero")
    func noDcZvaForANonZeroFill() {
        withZeroIdentification(0x4, mmu: true) {
            let range = zero(offset: 0, count: 4096, byte: 0x5A)
            #expect(range.intact)
            #expect(mmuCalls().isEmpty)
        }
    }

    @Test("no dc zva before the block size is loaded")
    func noDcZvaBeforeTheBlockIsLoaded() {
        withZeroIdentification(0x4, mmu: true) {
            Arch.MMU.zeroBlockBytes = 0
            let range = zero(offset: 0, count: 4096)
            #expect(range.intact)
            #expect(mmuCalls().isEmpty)
        }
    }
}
