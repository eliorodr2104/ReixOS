//
//  ELFPlannerTests.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

@Suite("ProcessServer ELF load planning")
struct ELFPlannerTests {

    @Test("a valid AArch64 image becomes bounded permission runs and copies")
    func validPlan() {
        var source = MemoryELF(validImage())
        guard case .success(let plan) = ELFPlanner.plan(from: &source) else {
            Issue.record("valid image was refused")
            return
        }

        #expect(plan.entry == TaskABI.programBase)
        #expect(plan.programBreak == TaskABI.programBase + 3 * TaskABI.pageSize)
        #expect(plan.imagePages == 3)
        #expect(plan.regionCount == 3)
        #expect(plan.copyCount == 3)
        #expect(plan.region(at: 0)?.permissions == [.read, .execute])
        #expect(plan.region(at: 1)?.permissions == [.read])
        #expect(plan.region(at: 2)?.permissions == [.read, .write])
        #expect(plan.copy(at: 2)?.virtualAddress == TaskABI.programBase + 0x2000)
    }

    @Test("page-level permission union rejects a split segment RWX page")
    func sharedPageWX() {
        var bytes = validImage()

        // The second segment is byte-disjoint from text but shares its page.
        // Its p_offset is congruent to its vaddr modulo p_align.
        let second = 64 + 56
        put64(&bytes, second + 8, 0x1800)
        put64(&bytes, second + 16, TaskABI.programBase + 0x800)
        put32(&bytes, second + 4, 0x6) // R|W

        var source = MemoryELF(bytes)
        #expect(planError(&source) == .writeExecuteConflict)
    }

    @Test("entry must land in an executable permission run")
    func executableEntry() {
        var bytes = validImage()
        put64(&bytes, 24, TaskABI.programBase + 0x1000)

        var source = MemoryELF(bytes)
        #expect(planError(&source) == .entryNotExecutable)
    }

    @Test("header tables and load segment counts are independently bounded")
    func bounds() {
        var tooManyHeaders = validImage()
        put16(&tooManyHeaders, 56, 65)
        var headerSource = MemoryELF(tooManyHeaders)
        #expect(planError(&headerSource) == .tooManyHeaders)

        let tooManySegments = imageWithLoadSegments(17)
        var segmentSource   = MemoryELF(tooManySegments)
        #expect(planError(&segmentSource) == .tooManySegments)
    }

    @Test("a truncated program header table is rejected before any plan exists")
    func truncatedTable() {
        var bytes = validImage()
        bytes.removeLast(bytes.count - 100)
        var source = MemoryELF(bytes)

        #expect(planError(&source) == .truncated)
    }
}

private func planError(_ source: inout MemoryELF) -> ELFPlanError? {
    guard case .failure(let error) = ELFPlanner.plan(from: &source) else {
        return nil
    }
    return error
}

private struct MemoryELF: ELFByteSource {
    let bytes: [UInt8]
    var size : UInt64 { UInt64(bytes.count) }

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableRawPointer,
        count           : Int
    ) -> Bool {
        guard offset <= UInt64(Int.max),
              count >= 0,
              Int(offset) <= bytes.count,
              count <= bytes.count - Int(offset)
        else { return false }

        bytes.withUnsafeBytes { raw in
            destination.copyMemory(
                from: raw.baseAddress! + Int(offset),
                byteCount: count
            )
        }
        return true
    }
}

private func validImage() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 0x3100)
    writeHeader(&bytes, count: 3, entry: TaskABI.programBase)

    writeProgramHeader(
        &bytes, index: 0,
        flags: 0x5, fileOffset: 0x1000,
        virtualAddress: TaskABI.programBase,
        fileSize: 0x100, memorySize: 0x100
    )
    writeProgramHeader(
        &bytes, index: 1,
        flags: 0x4, fileOffset: 0x2000,
        virtualAddress: TaskABI.programBase + 0x1000,
        fileSize: 0x80, memorySize: 0x80
    )
    writeProgramHeader(
        &bytes, index: 2,
        flags: 0x6, fileOffset: 0x3000,
        virtualAddress: TaskABI.programBase + 0x2000,
        fileSize: 0x20, memorySize: 0x800
    )
    return bytes
}

private func imageWithLoadSegments(_ count: Int) -> [UInt8] {
    let lastOffset = 0x1000 + count * 0x1000
    var bytes      = [UInt8](repeating: 0, count: lastOffset + 0x100)
    writeHeader(&bytes, count: count, entry: TaskABI.programBase)

    for index in 0..<count {
        writeProgramHeader(
            &bytes, index: index,
            flags: index == 0 ? 0x5 : 0x4,
            fileOffset: UInt64(0x1000 + index * 0x1000),
            virtualAddress: TaskABI.programBase + UInt64(index * 0x1000),
            fileSize: 0x10,
            memorySize: 0x10
        )
    }
    return bytes
}

private func writeHeader(
    _ bytes: inout [UInt8],
    count  : Int,
    entry  : UInt64
) {
    bytes[0] = 0x7F
    bytes[1] = 0x45
    bytes[2] = 0x4C
    bytes[3] = 0x46
    bytes[4] = 2
    bytes[5] = 1
    bytes[6] = 1
    put16(&bytes, 16, 2)
    put16(&bytes, 18, 0xB7)
    put32(&bytes, 20, 1)
    put64(&bytes, 24, entry)
    put64(&bytes, 32, 64)
    put16(&bytes, 52, 64)
    put16(&bytes, 54, 56)
    put16(&bytes, 56, UInt16(count))
}

private func writeProgramHeader(
    _ bytes       : inout [UInt8],
    index         : Int,
    flags         : UInt32,
    fileOffset    : UInt64,
    virtualAddress: UInt64,
    fileSize      : UInt64,
    memorySize    : UInt64
) {
    let base = 64 + index * 56
    put32(&bytes, base, 1)
    put32(&bytes, base + 4, flags)
    put64(&bytes, base + 8, fileOffset)
    put64(&bytes, base + 16, virtualAddress)
    put64(&bytes, base + 32, fileSize)
    put64(&bytes, base + 40, memorySize)
    put64(&bytes, base + 48, 0x1000)
}

private func put16(
    _ bytes : inout [UInt8],
    _ offset: Int,
    _ value : UInt16
) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func put32(
    _ bytes : inout [UInt8],
    _ offset: Int,
    _ value : UInt32
) {
    for index in 0..<4 {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
    }
}

private func put64(
    _ bytes : inout [UInt8],
    _ offset: Int,
    _ value : UInt64
) {
    for index in 0..<8 {
        bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
    }
}
