//
//  ELFWXPolicyTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// `.serialized` is not enough on its own: `loadELFFixture` parks the fixture
/// archive in `Kernel.platformInfo`, which every suite shares, so the run needs
/// `swift test --no-parallel` (see the `test` target in the Makefile).
extension KernelPolicyTestRoot {
@Suite("ELF W^X policy", .serialized)
struct ELFWXPolicyTests {

    /// Where the fixtures are placed. `UserSpaceLayout` rejects anything below
    /// `userMin`, so the loader never sees the low addresses a fake layout could
    /// get away with.
    private static let base = UserSpaceLayout.elfBaseTypical

    @Test("fixture headers match the ELF64 on-disk layout")
    func headerLayout() {
        #expect(MemoryLayout<Elf64_Ehdr_t>.size == 64)
        #expect(MemoryLayout<Elf64_Phdr_t>.size == 56)
    }

    @Test("a directly writable and executable segment is rejected before mutation")
    func directWriteExecuteSegment() throws {
        let outcome = try require(loadELFFixture([
            ELFSegmentFixture(flags: 0x7, virtual: Self.base, memorySize: 1, payload: [0xBB])
        ]))

        #expect(isWriteExecuteConflict(outcome.result), verdict(outcome))
        expectNoMutation(outcome)
    }

    @Test("two segments whose union covers one page are rejected before mutation")
    func overlappingSegments() throws {
        let outcome = try require(loadELFFixture([
            ELFSegmentFixture(flags: 0x5, virtual: Self.base,         memorySize: 0x800),
            ELFSegmentFixture(flags: 0x6, virtual: Self.base + 0x800, memorySize: 0x100)
        ]))

        #expect(isWriteExecuteConflict(outcome.result), verdict(outcome))
        expectNoMutation(outcome)
    }

    /// Pins the pass ordering, which the single-page fixtures above cannot: the
    /// offending page is the second one, so a loader that mapped each page as it
    /// cleared it would already have registered page zero and would report
    /// `.allocationFailed` from the staged page manager instead of the verdict.
    @Test("a later W+X page is rejected before the cleared page ahead of it is mapped")
    func writeExecutePageAfterACleanPage() throws {
        let outcome = try require(loadELFFixture([
            ELFSegmentFixture(flags: 0x5, virtual: Self.base,          memorySize: 1, payload: [0xAA]),
            ELFSegmentFixture(flags: 0x7, virtual: Self.base + 0x1000, memorySize: 1, payload: [0xBB])
        ]))

        #expect(isWriteExecuteConflict(outcome.result), verdict(outcome))
        expectNoMutation(outcome)
    }

    /// The positive control for both rejections above. A read-execute image is
    /// let through the gate and only then runs out of memory, so
    /// `.writeExecuteConflict` is a verdict the loader reaches on the layout and
    /// not one it returns for everything.
    @Test("a read-execute image reaches the mapping pass")
    func readExecuteImagePassesTheGate() throws {
        let outcome = try require(loadELFFixture([
            ELFSegmentFixture(flags: 0x5, virtual: Self.base, memorySize: 1, payload: [0xAA])
        ]))

        #expect(!isWriteExecuteConflict(outcome.result), verdict(outcome))
        #expect(isAllocationFailure(outcome.result), verdict(outcome))
    }

    @Test("page-separated read-execute and read-write segments reach the mapping pass")
    func pageSeparatedSegmentsPassTheGate() throws {
        let outcome = try require(loadELFFixture([
            ELFSegmentFixture(flags: 0x5, virtual: Self.base,          memorySize: 1, payload: [0xDD]),
            ELFSegmentFixture(flags: 0x6, virtual: Self.base + 0x1000, memorySize: 1, payload: [0xEE])
        ]))

        #expect(!isWriteExecuteConflict(outcome.result), verdict(outcome))
        #expect(isAllocationFailure(outcome.result), verdict(outcome))
    }


    // MARK: - Helpers

    /// No VMA registered, no frame allocated, no PTE published.
    private func expectNoMutation(_ outcome: ELFLoadOutcome) {
        #expect(outcome.vmaManagerUntouched)
        #expect(outcome.allocatedFrames == 0)
        #expect(outcome.publishedDescriptors == 0)
    }

    private func require(_ outcome: ELFLoadOutcome?) throws -> ELFLoadOutcome {
        try #require(outcome, "the fixture archive did not open")
    }

    private func isWriteExecuteConflict(_ result: Result<LoadedELF, ElfError>) -> Bool {
        if case .failure(.writeExecuteConflict) = result { return true }

        return false
    }

    private func isAllocationFailure(_ result: Result<LoadedELF, ElfError>) -> Bool {
        if case .failure(.allocationFailed) = result { return true }

        return false
    }

    private func verdict(_ outcome: ELFLoadOutcome) -> Comment {
        switch outcome.result {
            case .success(let image):
                Comment(rawValue: "accepted: \(image.loadBase)..<\(image.loadEnd)")

            case .failure(let error):
                Comment(rawValue: String(describing: error))
        }
    }
}


}
