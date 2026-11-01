//
//  InstructionPublicationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// How a range of freshly written code reaches the instruction side, decided by
/// CTR_EL0 as boot read it.
///
/// The decision is the subject because every wrong answer is silent: QEMU keeps
/// no instruction cache, so a kernel that skipped the clean, skipped the
/// invalidation, or invalidated by an address a VIPT cache does not index by
/// boots and runs exactly like a correct one. Each row below is one cache shape
/// a real core reports, and what the two halves of a publication must issue
/// for it, line sizes included: a line taken too large skips lines.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder and the loaded
/// cache type are both globals.
@Suite("Instruction publication", .serialized)
struct InstructionPublicationTests {

    /// One CTR_EL0 and what publishing a page under it has to issue.
    struct Shape: CustomTestStringConvertible, Sendable {
        let name    : String
        let ctr     : UInt64
        let stage   : [MMUOp]
        let complete: [MMUOp]
        let dataLine: UInt64
        let codeLine: UInt64

        var testDescription: String { name }
    }

    private static let idc: UInt64 = 1 << 28
    private static let dic: UInt64 = 1 << 29

    /// L1Ip in bits 15:14: 0b11 PIPT, 0b10 VIPT, 0b01 AIVIVT, 0b00 VPIPT.
    private static let vipt  : UInt64 = 0x8444_8004
    private static let pipt  : UInt64 = 0x8444_C004
    private static let aivivt: UInt64 = 0x8444_4004
    private static let vpipt : UInt64 = 0x8444_0004

    static let shapes: [Shape] = [
        Shape(name: "Cortex-A53, VIPT", ctr: vipt,
              stage: [.cleanPoU], complete: [.icacheAll], dataLine: 64, codeLine: 64),
        Shape(name: "PIPT", ctr: pipt,
              stage: [.cleanPoU, .icacheLines], complete: [.stream], dataLine: 64, codeLine: 64),
        Shape(name: "VIPT with IDC", ctr: vipt | idc,
              stage: [], complete: [.icacheAll], dataLine: 64, codeLine: 64),
        Shape(name: "PIPT with IDC", ctr: pipt | idc,
              stage: [.icacheLines], complete: [.stream], dataLine: 64, codeLine: 64),
        Shape(name: "VIPT with DIC", ctr: vipt | dic,
              stage: [.cleanPoU], complete: [.stream], dataLine: 64, codeLine: 64),
        Shape(name: "PIPT with DIC", ctr: pipt | dic,
              stage: [.cleanPoU], complete: [.stream], dataLine: 64, codeLine: 64),
        Shape(name: "IDC and DIC", ctr: pipt | idc | dic,
              stage: [], complete: [.stream], dataLine: 64, codeLine: 64),
        Shape(name: "AIVIVT is not PIPT", ctr: aivivt,
              stage: [.cleanPoU], complete: [.icacheAll], dataLine: 64, codeLine: 64),
        Shape(name: "VPIPT is not PIPT", ctr: vpipt,
              stage: [.cleanPoU], complete: [.icacheAll], dataLine: 64, codeLine: 64),
        Shape(name: "128-byte data lines, 32-byte code lines", ctr: 0x8445_C003,
              stage: [.cleanPoU, .icacheLines], complete: [.stream], dataLine: 128, codeLine: 32),
        Shape(name: "never loaded", ctr: 0,
              stage: [.cleanPoU], complete: [.icacheAll], dataLine: 4, codeLine: 4),
    ]


    private static let page = UnsafeMutableRawPointer(bitPattern: 0x4010_2000)!


    @Test("staging issues the per-range half the cache needs, at its line size", arguments: shapes)
    func stageMatchesTheCache(_ shape: Shape) {
        withCacheType(shape.ctr) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            Arch.MMU.stageInstructions(Self.page, size: UserSpaceLayout.pageSize)

            let calls = mmuCalls()
            #expect(calls.map(\.op) == shape.stage)

            for call in calls {
                #expect(call.arg  == UInt64(UInt(bitPattern: Self.page)))
                #expect(call.size == UserSpaceLayout.pageSize)
                #expect(call.line == (call.op == .cleanPoU ? shape.dataLine : shape.codeLine))
            }
        }
    }


    @Test("completing issues one whole-cache invalidation or only the wait", arguments: shapes)
    func completeMatchesTheCache(_ shape: Shape) {
        withCacheType(shape.ctr) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            Arch.MMU.completeInstructionPublication()

            #expect(mmuOps() == shape.complete)
        }
    }


    @Test("a batch of pages costs one completion, however many were staged")
    func batchCompletesOnce() {
        withCacheType(Self.vipt) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            for index in 0..<8 {
                Arch.MMU.stageInstructions(
                    Self.page + index * Int(UserSpaceLayout.pageSize),
                    size: UserSpaceLayout.pageSize
                )
            }

            Arch.MMU.completeInstructionPublication()

            #expect(mmuOps() == Array(repeating: .cleanPoU, count: 8) + [.icacheAll])
        }
    }


    @Test("a range smaller than a page is staged as given")
    func partialRangeIsStagedAsGiven() {
        withCacheType(Self.pipt) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            let base = Self.page + 100

            Arch.MMU.stageInstructions(base, size: 300)

            #expect(mmuCalls().map(\.arg)  == [UInt64(UInt(bitPattern: base)), UInt64(UInt(bitPattern: base))])
            #expect(mmuCalls().map(\.size) == [300, 300])
        }
    }


    @Test("CTR_EL0 is read when boot loads it and never again")
    func cacheTypeIsReadOnce() {
        withCacheType(Self.vipt) {
            #expect(Arch.MMU.cacheType == Self.vipt)

            // The register now reads a different machine. A publication that read
            // it again would take its line sizes and its policy from this one.
            host_set_cache_type(0x8445_C003)

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            Arch.MMU.stageInstructions(Self.page, size: UserSpaceLayout.pageSize)
            Arch.MMU.completeInstructionPublication()

            #expect(mmuOps() == [.cleanPoU, .icacheAll])
            #expect(mmu_trace_line(0) == 64)
            #expect(Arch.MMU.cacheType == Self.vipt)
        }
    }
}
