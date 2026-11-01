//
//  InstructionPublicationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// How a range of freshly written code reaches the instruction side, decided by
/// CTR_EL0 and MIDR_EL1 as boot read them.
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


    struct Part: CustomTestStringConvertible, Sendable {
        let name : String
        let midr : UInt64
        let clean: MMUOp

        var testDescription: String { name }
    }

    static let parts: [Part] = [
        Part(name: "A53 r0p0", midr: 0x410F_D030, clean: .cleanPoC),
        Part(name: "A53 r0p1", midr: 0x410F_D031, clean: .cleanPoC),
        Part(name: "A53 r0p2", midr: 0x410F_D032, clean: .cleanPoC),
        Part(name: "A53 r0p3", midr: 0x410F_D033, clean: .cleanPoU),
        Part(name: "A53 r0p15", midr: 0x410F_D03F, clean: .cleanPoU),
        Part(name: "A53 r1p0", midr: 0x411F_D030, clean: .cleanPoU),
        Part(name: "A53 r1p2", midr: 0x411F_D032, clean: .cleanPoU),
        Part(name: "other implementer", midr: 0x420F_D030, clean: .cleanPoU),
        Part(name: "adjacent part below", midr: 0x410F_D020, clean: .cleanPoU),
        Part(name: "adjacent part above", midr: 0x410F_D040, clean: .cleanPoU),
        Part(name: "other architecture", midr: 0x410E_D030, clean: .cleanPoU),
        Part(name: "no MIDR loaded", midr: 0, clean: .cleanPoU),
    ]


    @Test("only affected A53 revisions clean and invalidate to PoC", arguments: parts)
    func cleanMatchesThePart(_ part: Part) {
        withCacheType(Self.vipt, midr: part.midr) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            let base = Self.page + 100
            Arch.MMU.stageInstructions(base, size: 300)

            #expect(mmuCalls() == [MMUCall(
                op: part.clean, arg: UInt64(UInt(bitPattern: base)), size: 300, line: 64
            )])

            Arch.MMU.completeInstructionPublication()
            #expect(mmuOps() == [part.clean, .icacheAll])
        }
    }


    @Test("MIDR_EL1 is read with CTR_EL0 at boot, never per range", arguments: [false, true])
    func mainIDIsReadOnce(_ affected: Bool) {
        let reads = host_main_id_reads()
        withCacheType(Self.vipt, midr: affected ? 0x410F_D032 : 0x410F_D033) {
            #expect(host_main_id_reads() == reads + 1)
            host_set_main_id(affected ? 0x410F_D033 : 0x410F_D032)

            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            Arch.MMU.stageInstructions(Self.page, size: 4096)
            Arch.MMU.stageInstructions(Self.page + 4096, size: 4096)
            Arch.MMU.completeInstructionPublication()

            let clean: MMUOp = affected ? .cleanPoC : .cleanPoU
            #expect(mmuOps() == [clean, clean, .icacheAll])
            #expect(host_main_id_reads() == reads + 1)
        }
    }


    @Test("the workaround preserves IDC, DIC and PIPT ordering", arguments: shapes)
    func workaroundPreservesTheCachePolicy(_ shape: Shape) {
        withCacheType(shape.ctr, midr: 0x410F_D032) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            Arch.MMU.stageInstructions(Self.page, size: 4096)
            Arch.MMU.completeInstructionPublication()

            let stage = shape.stage.map { $0 == .cleanPoU ? MMUOp.cleanPoC : $0 }
            #expect(mmuOps() == stage + shape.complete)

            for call in mmuCalls() where call.op == .cleanPoC || call.op == .icacheLines {
                #expect(call.arg == 0x4010_2000)
                #expect(call.size == 4096)
                #expect(call.line == (call.op == .cleanPoC ? shape.dataLine : shape.codeLine))
            }
        }
    }
}
