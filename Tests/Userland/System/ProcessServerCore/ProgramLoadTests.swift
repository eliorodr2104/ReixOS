//
//  ProgramLoadTests.swift
//  ReixOS
//

import Testing
import ReixABI
@testable import ProcessServerCore

@Suite("ProcessServer program loading")
struct ProgramLoadTests {
    @Test func removedBeforeClaimIsNotFound() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.remove(by: ProgramShelf.writer) == .ok)
        var file = ShelfProgram(shelf)
        #expect(throws: ProcessServerStatus.notFound) { try ProgramLoad.begin(&file) }
        #expect(shelf.reads == 0)
        #expect(shelf.releases == 0)
    }

    @Test func claimedByWriterIsBusy() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.lock(by: ProgramShelf.writer) == .ok)
        var file = ShelfProgram(shelf)
        #expect(throws: ProcessServerStatus.busy) { try ProgramLoad.begin(&file) }
        #expect(shelf.reads == 0)
        #expect(shelf.releases == 0)
        #expect(shelf.lock(by: ProgramShelf.loader) == .busy)
        #expect(shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer) == .ok)
    }

    @Test func busyIsNotRetried() {
        let shelf = ProgramShelf(patternedImage())
        #expect(shelf.lock(by: ProgramShelf.writer) == .ok)
        var file = ShelfProgram(shelf)
        #expect(throws: ProcessServerStatus.busy) { try ProgramLoad.begin(&file) }
        #expect(shelf.claims == 1)
    }

    @Test func malformedLetsGo() {
        var bytes = patternedImage()
        bytes[1] = 0
        let shelf = ProgramShelf(bytes)
        var file = ShelfProgram(shelf)
        #expect(throws: ProcessServerStatus.malformedELF) { try ProgramLoad.begin(&file) }
        #expect(shelf.releasedForTheWriter())
    }

    @Test func deadLoaderIsSwept() throws {
        let shelf = ProgramShelf(patternedImage())
        var before: FSStatus?
        var after: FSStatus?
        shelf.onRead = { shelf, index in
            guard index == 3 else { return }
            before = shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer)
            shelf.dead.insert(ProgramShelf.loader)
            after = shelf.write(0xEE, at: 0x1000, by: ProgramShelf.writer)
        }
        var file = ShelfProgram(shelf)
        let plan = try ProgramLoad.begin(&file)
        var image = TaskImage()
        #expect(image.copy(plan, from: &file) == .ok)
        file.release()
        #expect(before == .busy)
        #expect(after == .ok)
    }

    @Test func claimAnswers() {
        #expect(ProcessServerStatus(claiming: .ok) == .ok)
        #expect(ProcessServerStatus(claiming: .busy) == .busy)
        #expect(ProcessServerStatus(claiming: .notFound) == .notFound)
        #expect(ProcessServerStatus(claiming: .readOnly) == .unavailable)
        #expect(ProcessServerStatus(claiming: .unreachable) == .unavailable)
    }

    @Test func copyMovesOnePagePerStep() throws {
        let shelf = ProgramShelf(patternedImage())
        var file = ShelfProgram(shelf)
        let plan = try ProgramLoad.begin(&file)
        var copy = ProgramCopy()
        var steps = 0
        var expected = 0
        for i in 0..<plan.copyCount { expected += Int((plan.copy(at: i)!.byteCount + 4095) / 4096) }
        while !copy.isDone(plan) && steps < 1000 {
            let reads = shelf.reads
            var writes = 0
            let moved = copy.step(plan, from: &file) { _, _, count in
                #expect(count > 0 && count <= 4096)
                writes += 1
                return true
            }
            #expect(moved)
            #expect(shelf.reads == reads + 1)
            #expect(writes == 1)
            steps += 1
        }
        #expect(copy.isDone(plan))
        #expect(steps == expected)
        let reads = shelf.reads
        #expect(copy.step(plan, from: &file) { _, _, _ in Issue.record("wrote after done"); return true })
        #expect(shelf.reads == reads)
        file.release()
    }

    @Test(arguments: [0, 1, 4096, 4097])
    func copyBoundaries(_ count: Int) {
        var copies = InlineArray<16, ELFCopy?>(repeating: nil)
        copies[0] = ELFCopy(fileOffset: 0, virtualAddress: 0x10000, byteCount: 0)
        copies[1] = ELFCopy(fileOffset: 0, virtualAddress: 0x20000, byteCount: UInt64(count))
        let regions = InlineArray<31, ELFLoadRegion?>(repeating: nil)
        let plan = ELFLoadPlan(entry: 0, programBreak: 0, imagePages: 0,
            regions: regions, regionCount: 0, copies: copies, copyCount: 2)
        let empty = ELFLoadPlan(entry: 0, programBreak: 0, imagePages: 0,
            regions: regions, regionCount: 0, copies: copies, copyCount: 0)
        var source = MemoryProgram([UInt8](repeating: 7, count: 8192))
        var copy = ProgramCopy()
        #expect(copy.isDone(empty))
        let index = copy.index, offset = copy.offset
        #expect(copy.isDone(plan) == (count == 0))
        #expect(copy.index == index && copy.offset == offset)
        var steps = 0
        while !copy.isDone(plan) && steps < 1000 {
            #expect(copy.step(plan, from: &source) { _, _, bytes in bytes > 0 && bytes <= 4096 })
            steps += 1
        }
        #expect(copy.isDone(plan))
        #expect(steps == (count + 4095) / 4096)
    }

    @Test func copyReadFailureStops() throws {
        let shelf = ProgramShelf(patternedImage())
        var file = ShelfProgram(shelf)
        let plan = try ProgramLoad.begin(&file)
        shelf.failReads = true
        var copy = ProgramCopy()
        #expect(!copy.step(plan, from: &file) { _, _, _ in Issue.record("wrote a failed read"); return true })
        #expect(copy.index == 0 && copy.offset == 0)
        file.release()
    }

    @Test func copyWriteFailureStops() throws {
        let shelf = ProgramShelf(patternedImage())
        var file = ShelfProgram(shelf)
        let plan = try ProgramLoad.begin(&file)
        var copy = ProgramCopy()
        #expect(copy.step(plan, from: &file) { _, _, _ in true })
        let index = copy.index, offset = copy.offset
        #expect(!copy.step(plan, from: &file) { _, _, _ in false })
        #expect(copy.index == index && copy.offset == offset)
        file.release()
    }

    @Test func copiedImageMatchesPlan() throws {
        let shelf = ProgramShelf(patternedImage())
        let original = shelf.bytes
        var file = ShelfProgram(shelf)
        let plan = try ProgramLoad.begin(&file)
        var image = TaskImage()
        #expect(image.copy(plan, from: &file) == .ok)
        #expect(image.matches(plan, in: original))
        file.release()
        #expect(shelf.releasedForTheWriter())
    }
}
