//
//  ProgramLoadTests.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

/// A load against a file somebody else wants to change.
///
/// Every case needs two holders of one file, a loader and a writer, so the file
/// sits on a pretend shelf with the claim table the file system server keeps
/// (`FSLeases`) and the server's rule around it: a refusal is asked twice, with
/// the dead holders swept in between.
@Suite("ProcessServer program loading")
struct ProgramLoadTests {

    @Test("a write while a program loads is refused and the image is the version planned")
    func writesDuringLoadAreRefused() {
        let shelf    = ProgramShelf(patternedImage())
        let original = shelf.bytes
        var refusals: [FSStatus] = []

        // At every read, from the first header byte, and at every page copied
        // into the task, up to the last: a writer tries to change the program.
        shelf.onRead = { shelf, _ in
            refusals.append(shelf.write(0xEE, at: 24, by: ProgramShelf.writer))
            refusals.append(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer))
        }

        var file  = ShelfProgram(shelf)
        var image = TaskImage()

        let status = ProgramLoad.load(&file) { plan, claimed in
            image.copy(plan, from: &claimed) {
                refusals.append(shelf.write(0xEE, at: 0x3000, by: ProgramShelf.writer))
            }
        }

        #expect(status == .ok)
        #expect(!refusals.isEmpty)
        #expect(refusals.allSatisfy { $0 == .busy })
        #expect(shelf.bytes == original)

        var planned = MemoryProgram(original)
        guard case .success(let plan) = ELFPlanner.plan(from: &planned) else {
            Issue.record("the fixture does not plan")
            return
        }
        #expect((plan.copy(at: 2)?.byteCount ?? 0) > UInt64(2 * ProgramLoad.chunk))
        #expect(image.matches(plan, in: original))
        #expect(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer) == .ok)
    }


    @Test("a remove while a program loads is refused")
    func removeDuringLoadIsRefused() {
        let shelf   = ProgramShelf(patternedImage())
        var removed : FSStatus?

        shelf.onRead = { shelf, index in
            if index == 3 { removed = shelf.remove(by: ProgramShelf.writer) }
        }

        var file  = ShelfProgram(shelf)
        var image = TaskImage()

        let status = ProgramLoad.load(&file) { plan, claimed in
            image.copy(plan, from: &claimed)
        }

        #expect(status == .ok)
        #expect(removed == .busy)
        #expect(shelf.generation != nil)
    }


    @Test("a file removed before the claim reaches nothing and is not read")
    func removedBeforeClaimIsNotFound() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.remove(by: ProgramShelf.writer) == .ok)

        var file  = ShelfProgram(shelf)
        var built = false

        let status = ProgramLoad.load(&file) { _, _ in
            built = true
            return .ok
        }

        #expect(status == .notFound)
        #expect(!built)
        #expect(shelf.reads == 0)
        #expect(shelf.releases == 0)
    }


    @Test("a program a writer holds is refused busy and not read")
    func claimedByWriterIsBusy() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.lock(by: ProgramShelf.writer) == .ok)

        var file  = ShelfProgram(shelf)
        var built = false

        let status = ProgramLoad.load(&file) { _, _ in
            built = true
            return .ok
        }

        #expect(status == .busy)
        #expect(!built)
        #expect(shelf.reads == 0)

        // Nothing let go on a claim this load never held: the writer keeps it.
        #expect(shelf.releases == 0)
        #expect(shelf.lock(by: ProgramShelf.loader) == .busy)
        #expect(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer) == .ok)
    }


    @Test("a busy claim is asked once and not waited out")
    func busyIsNotRetried() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.lock(by: ProgramShelf.writer) == .ok)

        var file = ShelfProgram(shelf)
        let status = ProgramLoad.load(&file) { _, _ in .ok }

        #expect(status == .busy)
        #expect(shelf.claims == 1)
    }


    // MARK: - Let go on every way out

    @Test("a malformed image lets go of its claim")
    func malformedLetsGo() {
        var bytes = patternedImage()
        bytes[1]  = 0

        let shelf = ProgramShelf(bytes)
        var file  = ShelfProgram(shelf)
        var built = false

        let status = ProgramLoad.load(&file) { _, _ in
            built = true
            return .ok
        }

        #expect(status == .malformedELF)
        #expect(!built)
        #expect(shelf.releasedForTheWriter())
    }


    @Test("a task that cannot be made lets go of the claim")
    func taskFailureLetsGo() {
        let shelf  = ProgramShelf(patternedImage())
        var file   = ShelfProgram(shelf)
        let status = ProgramLoad.load(&file) { _, _ in .taskFailure }

        #expect(status == .taskFailure)
        #expect(shelf.releasedForTheWriter())
    }


    @Test("a task write that fails part way lets go of the claim")
    func copyWriteFailureLetsGo() {
        let shelf = ProgramShelf(patternedImage())
        var file  = ShelfProgram(shelf)
        var pages = 0

        let status = ProgramLoad.load(&file) { plan, claimed in
            let copied = ProgramLoad.copy(plan, from: &claimed) { _, _, _ in
                pages += 1
                return pages < 2
            }
            return copied ? .ok : .taskFailure
        }

        #expect(status == .taskFailure)
        #expect(pages == 2)
        #expect(shelf.releasedForTheWriter())
    }


    @Test("a file read that fails part way lets go of the claim")
    func copyReadFailureLetsGo() {
        let shelf = ProgramShelf(patternedImage())
        var file  = ShelfProgram(shelf)
        var image = TaskImage()

        let status = ProgramLoad.load(&file) { plan, claimed in
            shelf.failReads = true
            return image.copy(plan, from: &claimed)
        }

        #expect(status == .taskFailure)
        #expect(shelf.releasedForTheWriter())
    }


    @Test("a refusal by ProcessServer under the claim lets go of it")
    func refusalLetsGo() {
        let shelf  = ProgramShelf(patternedImage())
        var file   = ShelfProgram(shelf)
        let status = ProgramLoad.load(&file) { _, _ in .unavailable }

        #expect(status == .unavailable)
        #expect(shelf.releasedForTheWriter())
    }


    @Test("a program that loads lets go of the claim")
    func successLetsGo() {
        let shelf = ProgramShelf(patternedImage())
        var file  = ShelfProgram(shelf)
        var image = TaskImage()

        let status = ProgramLoad.load(&file) { plan, claimed in
            image.copy(plan, from: &claimed)
        }

        #expect(status == .ok)
        #expect(shelf.releasedForTheWriter())
    }


    /// The loader's claim is held by its identity, and a dead identity's claims
    /// go in the sweep a refusal triggers, which is the server's own rule.
    @Test("a loader that dies holding the claim does not hold it for ever")
    func deadLoaderIsSwept() {
        let shelf = ProgramShelf(patternedImage())
        var before: FSStatus?
        var after : FSStatus?

        shelf.onRead = { shelf, index in
            guard index == 3 else { return }
            before = shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer)
            shelf.dead.insert(ProgramShelf.loader)
            after = shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer)
        }

        var file = ShelfProgram(shelf)
        _ = ProgramLoad.load(&file) { plan, claimed in
            var image = TaskImage()
            return image.copy(plan, from: &claimed)
        }

        #expect(before == .busy)
        #expect(after == .ok)
    }


    @Test("the file system's answer to a claim becomes the launch's")
    func claimAnswers() {
        #expect(ProcessServerStatus(claiming: .ok) == .ok)
        #expect(ProcessServerStatus(claiming: .busy) == .busy)
        #expect(ProcessServerStatus(claiming: .notFound) == .notFound)

        // A view without the right, or a server that cannot be reached, is a
        // file system this launch cannot use, never a program that is not there.
        #expect(ProcessServerStatus(claiming: .readOnly) == .unavailable)
        #expect(ProcessServerStatus(claiming: .unreachable) == .unavailable)
    }
}


// MARK: - The shelf

/// One program file, its incarnation, and the claims on it.
private final class ProgramShelf {
    static let object: UInt32 = 12
    static let loader: UInt32 = 1
    static let writer: UInt32 = 2

    var bytes     : [UInt8]
    var generation: UInt32? = 7
    var leases    = FSLeases()
    var dead      : Set<UInt32> = []
    var failReads = false

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
        releases == 1 && write(0xEE, at: 0x1000, by: Self.writer) == .ok
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
private struct ShelfProgram: ProgramFile {
    let shelf: ProgramShelf
    private(set) var size: UInt64 = 0

    init(_ shelf: ProgramShelf) {
        self.shelf = shelf
    }

    mutating func claim() -> ProcessServerStatus {
        shelf.claims += 1

        let claimed = ProcessServerStatus(claiming: shelf.lock(by: ProgramShelf.loader))
        guard claimed == .ok else { return claimed }

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
private struct TaskImage {
    var bytes: [UInt64: UInt8] = [:]

    /// Copies `plan` in, running `eachPage` after every page lands.
    mutating func copy(
        _ plan     : ELFLoadPlan,
        from file  : inout ShelfProgram,
        eachPage   : () -> Void = {}
    ) -> ProcessServerStatus {
        let copied = ProgramLoad.copy(plan, from: &file) { address, page, count in
            for index in 0..<count {
                bytes[address + UInt64(index)] = page.load(fromByteOffset: index, as: UInt8.self)
            }
            eachPage()
            return true
        }
        return copied ? .ok : .taskFailure
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
private struct MemoryProgram: ELFByteSource {
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
private func patternedImage() -> [UInt8] {
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
