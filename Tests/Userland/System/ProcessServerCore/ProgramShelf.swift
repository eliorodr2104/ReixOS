//
//  ProgramShelf.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

/// One program file, its incarnation, and the claims on it.
final class ProgramShelf {
    static let object: UInt32 = 12
    static let loader: UInt32 = 1
    static let writer: UInt32 = 2

    var bytes     : [UInt8]
    var generation: UInt32? = 7
    var leases    = FSLeases()
    var dead      : Set<UInt32> = []
    var failReads = false

    var successfulClaims = 0
    var claims   = 0
    var releases = 0
    var reads    = 0

    /// Called before each of the loader's reads, with how many came before it.
    var onRead: ((ProgramShelf, Int) -> Void)?

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// The server's `lock`: nothing for a file that is gone, and a refusal only
    /// after the dead holders are swept.
    func lock(by holder: UInt32) -> FSStatus {
        guard let generation else { return .notFound }

        if leases.claim(Self.object, generation: generation, for: holder) { return .ok }
        sweep()
        return leases.claim(Self.object, generation: generation, for: holder) ? .ok : .busy
    }

    func unlock(by holder: UInt32) {
        leases.release(Self.object, from: holder)
    }

    func write(_ value: UInt8, at offset: Int, by holder: UInt32) -> FSStatus {
        guard generation != nil else { return .notFound }
        guard mayChange(by: holder) else { return .busy }

        bytes[offset] = value
        return .ok
    }

    func remove(by holder: UInt32) -> FSStatus {
        guard generation != nil else { return .notFound }
        guard mayChange(by: holder) else { return .busy }

        generation = nil
        return .ok
    }

    /// Let go exactly once, and the writer can change the file again.
    func releasedForTheWriter() -> Bool {
        releases == successfulClaims && releases > 0 && write(0xEE, at: 0x1000, by: Self.writer) == .ok
    }

    private func mayChange(by holder: UInt32) -> Bool {
        if leases.mayChange(Self.object, generation: generation, by: holder) { return true }
        sweep()
        return leases.mayChange(Self.object, generation: generation, by: holder)
    }

    private func sweep() {
        for holder in dead { leases.forget(everythingHeldBy: holder) }
    }
}


/// The loader's view of the shelf.
struct ShelfProgram: ProgramFile {
    let shelf: ProgramShelf
    private(set) var size: UInt64 = 0

    init(_ shelf: ProgramShelf) {
        self.shelf = shelf
    }

    mutating func claim() -> ProcessServerStatus {
        shelf.claims += 1

        let claimed = ProcessServerStatus(claiming: shelf.lock(by: ProgramShelf.loader))
        guard claimed == .ok else { return claimed }

        shelf.successfulClaims += 1
        size = UInt64(shelf.bytes.count)
        return .ok
    }

    mutating func release() {
        shelf.releases += 1
        shelf.unlock(by: ProgramShelf.loader)
    }

    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableRawPointer,
        count           : Int
    ) -> Bool {
        shelf.onRead?(shelf, shelf.reads)
        shelf.reads += 1

        guard !shelf.failReads,
              shelf.generation != nil,
              count >= 0,
              offset <= UInt64(shelf.bytes.count),
              count <= shelf.bytes.count - Int(offset)
        else { return false }

        shelf.bytes.withUnsafeBytes { raw in
            destination.copyMemory(from: raw.baseAddress! + Int(offset), byteCount: count)
        }
        return true
    }
}


/// The bytes of a planned image as it would sit in a task, by address.
struct TaskImage {
    var bytes: [UInt64: UInt8] = [:]

    /// Copies `plan` in, running `eachPage` after every page lands.
    mutating func copy(
        _ plan     : ELFLoadPlan,
        from file  : inout ShelfProgram,
        eachPage   : () -> Void = {}
    ) -> ProcessServerStatus {
        var copy = ProgramCopy()
        for _ in 0..<1000 {
            if copy.isDone(plan) { return .ok }
            guard copy.step(plan, from: &file, into: { address, page, count in
                for index in 0..<count {
                    bytes[address + UInt64(index)] = page.load(fromByteOffset: index, as: UInt8.self)
                }
                eachPage()
                return true
            }) else { return .taskFailure }
        }
        Issue.record("copy did not finish in 1000 steps")
        return .taskFailure
    }

    /// Whether every byte `plan` copies holds what `file` had at its offset.
    func matches(_ plan: ELFLoadPlan, in file: [UInt8]) -> Bool {
        var total = 0
        for index in 0..<plan.copyCount {
            guard let copy = plan.copy(at: index) else { return false }
            for byte in 0..<Int(copy.byteCount) {
                let at = copy.virtualAddress + UInt64(byte)
                guard bytes[at] == file[Int(copy.fileOffset) + byte] else { return false }
                total += 1
            }
        }
        return total > 0 && total == bytes.count
    }
}


/// A planner source over plain bytes, for the plan a test compares against.
struct MemoryProgram: ELFByteSource {
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
        guard offset <= UInt64(bytes.count), count <= bytes.count - Int(offset) else { return false }

        bytes.withUnsafeBytes { raw in
            destination.copyMemory(from: raw.baseAddress! + Int(offset), byteCount: count)
        }
        return true
    }
}


/// The planner's valid image with its data segment grown past two pages and
/// every segment byte set, so each page of a copy lands somewhere it can be told
/// from an untouched byte, from its neighbour, and from a writer's 0xEE.
func patternedImage() -> [UInt8] {
    let data  = 0x2100
    var bytes = validImage()
    bytes += [UInt8](repeating: 0, count: 0x3000 + data - bytes.count)

    // The third program header's file and memory sizes.
    for (offset, value) in [(64 + 2 * 56 + 32, data), (64 + 2 * 56 + 40, data)] {
        for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    for offset in 0x1000..<bytes.count { bytes[offset] = UInt8(truncatingIfNeeded: offset % 251) }
    return bytes
}
