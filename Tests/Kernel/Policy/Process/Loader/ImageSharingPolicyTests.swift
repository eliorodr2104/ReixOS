//
//  ImageSharingPolicyTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// `ImageSharing`, the gate that decides whether a PT_LOAD segment is mapped
/// straight out of the initrd instead of being copied into frames of its own.
///
/// Every condition it takes is a way the alias would be unsafe, so each test here
/// satisfies all of them but one and asserts the verdict flips. The accept path is
/// asserted too: a gate that refused everything would pass a refusal-only suite
/// and quietly turn page sharing off.
///
/// ## What is real and what is staged
///
/// Real: `ImageSharing`, `TarFileSystem` (the archive is walked and opened by it,
/// so `residentBase` and the member size are its answers and not the fixture's),
/// the page-aligned ustar layout `UstarWriter` gives the real initrd, the
/// `Elf64_*_t` headers, and `UserSpaceLayout`'s range arithmetic. The segment
/// headers the gate is asked about are read back out of the staged image.
///
/// Staged: the initrd window, parked in `Kernel.platformInfo` around a host
/// allocation, and the arena that stands in for RAM.
///
/// ## The three ways a test here asks the question
///
/// `withImage` puts the gate's inputs in front of it and reads the verdict, which
/// is where the conditions are isolated one at a time: the answer is a page count,
/// and a refused tail also lands in `ImageSharing.declinedTailPages`.
///
/// `withLoadedImage` runs the whole loader over a live page manager and kernel
/// heap, so the ownership shape is read back rather than inferred: the VMAs it
/// registered, what each page resolves to, and the bytes a process in that address
/// space would see. That is the half of the contract a verdict cannot state, and
/// it needs the two host seams `withLoadedELFImage` documents.
///
/// `loadCountingDeclines` runs the loader over the *staged* page manager, where the
/// first `registerRegion` fails and the verdict is `.allocationFailed`. Kept for
/// the unaligned layout every other ELF fixture uses, which is exactly the shape
/// `ELFWXPolicyTests` depends on.
///
/// `.serialized` is not enough on its own: the fixture parks the archive in
/// `Kernel.platformInfo` and moves `PPMBackend.physicalOffset`, both of which every
/// suite shares, so the run needs `swift test --no-parallel` (see the `test` target
/// in the Makefile).
extension KernelPolicyTestRoot {
@Suite("ELF initrd sharing policy", .serialized)
struct ImageSharingPolicyTests {

    /// Where the fixtures are placed. `UserSpaceLayout` rejects anything below
    /// `userMin`, so the gate never sees the low addresses a fake layout could get
    /// away with.
    private static let base = UserSpaceLayout.elfBaseTypical

    private static let page: UInt64 = UserSpaceLayout.pageSize


    @Test("a page-aligned read-execute segment is aliased page for page out of the archive")
    func fullPagesAreAliased() {
        withImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            var shared: UInt64 = 0
            let declined = declinedTails { shared = image.shareablePages(of: 0) }

            #expect(shared == 2)
            #expect(image.pageCount(of: 0) == 2)
            #expect(declined == 0)

            // Both pages come from the member's own bytes, on page boundaries, and
            // inside the archive: an alias that left it would outlive the initrd.
            let offset = image.fileOffset(of: 0)
            #expect(image.aliasedPages(of: 0, count: shared) == [
                image.residentBase + offset,
                image.residentBase + offset + Self.page
            ])
            #expect(offset % Self.page == 0)
            #expect(image.residentBase % Self.page == 0)
            #expect(image.residentBase + offset + shared * Self.page <= image.initrdEnd)
        }
    }


    @Test("a writable segment is copied no matter how it is aligned")
    func writableSegmentIsNeverAliased() {
        withImage([
            ELFSegmentFixture(
                flags     : 0x6,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            // Same alignment as the accepted case above, so `.write` is the only
            // reason left: one process could otherwise rewrite another's image.
            #expect(image.shareablePages(of: 0) == 0)
            #expect(image.pageCount(of: 0) == 2)
        }
    }


    @Test("a tail page whose bytes past p_filesz are zero is aliased with the rest")
    func zeroPaddedTailIsAliased() {
        withImage([Self.segmentWithTail(padding: zeros(Self.page - 100))]) { image in
            var shared: UInt64 = 0
            let declined = declinedTails { shared = image.shareablePages(of: 0) }

            // The linker pads every image to the next page, which is the case that
            // has to keep working: 4196 bytes of file cover two whole pages.
            #expect(shared == 2)
            #expect(declined == 0)
        }
    }


    @Test("a tail page with a non-zero byte past p_filesz is refused and counted")
    func nonZeroTailIsCopied() {
        var padding  = zeros(Self.page - 100)
        padding[0]   = 0xFF

        withImage([Self.segmentWithTail(padding: padding)]) { image in
            var shared: UInt64 = 0
            let declined = declinedTails { shared = image.shareablePages(of: 0) }

            // The full page keeps its alias and only the tail falls back, so the
            // refusal costs one frame and not the segment.
            #expect(shared == 1)
            #expect(image.pageCount(of: 0) == 2)
            #expect(declined == 1)
        }
    }


    @Test("a tail page that would read past the end of the archive member is refused")
    func tailPastTheMemberIsRefused() {
        // The member ends where its bytes do, with no padding of its own, and
        // another member follows it in the archive.
        withImage(
            [Self.segmentWithTail(padding: [])],
            followedBy: filled(Self.page, 0xFF)
        ) { image in
            var shared: UInt64 = 0
            let declined = declinedTails { shared = image.shareablePages(of: 0) }

            #expect(shared == 1)
            #expect(declined == 1)

            // What the refusal is worth: the page would have covered the filler and
            // the next member's header, bytes no process asked for.
            #expect(image.hasNonZeroByte(
                from: image.fileSize,
                to  : image.fileOffset(of: 0) + 2 * Self.page
            ))
        }
    }


    @Test("two segments sharing a page decline sharing for both of them")
    func overlappingSegmentsDeclineBoth() {
        let overlapping = [
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            ),
            ELFSegmentFixture(
                flags     : 0x4,
                virtual   : Self.base + Self.page,
                memorySize: Self.page,
                payload   : filled(Self.page)
            )
        ]

        withImage(overlapping) { image in
            #expect(image.segmentCount == 2)

            // One page-table entry cannot hold two permission sets, so neither
            // segment may claim the page they both cover.
            #expect(image.shareablePages(of: 0) == 0)
            #expect(image.shareablePages(of: 1) == 0)
        }

        // Read-execute over read-only is a union the W^X pass allows, so the loader
        // still reaches the mapping pass and copies the pages.
        expectReachesMappingPass(overlapping, layout: .shareable)
    }


    @Test("an unaligned p_offset, resident base or p_vaddr declines the whole segment")
    func unalignedLayoutsDeclineWholesale() {
        let segment = ELFSegmentFixture(
            flags     : 0x5,
            virtual   : Self.base,
            memorySize: 2 * Self.page,
            payload   : filled(2 * Self.page)
        )

        // A page can only be aliased whole, so bytes straddling a boundary are
        // copied. Each layout below fails exactly one of the three alignments.
        withImage([segment], layout: .unalignedOffsets) { image in
            #expect(image.fileOffset(of: 0) % Self.page != 0)
            #expect(image.shareablePages(of: 0) == 0)
        }

        withImage([segment], layout: .unalignedBase) { image in
            #expect(image.residentBase % Self.page != 0)
            #expect(image.shareablePages(of: 0) == 0)
        }

        withImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base + 0x800,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            #expect(image.shareablePages(of: 0) == 0)
        }
    }


    @Test("a segment with no file bytes is never aliased")
    func zeroFillSegmentIsPrivate() {
        withImage([
            ELFSegmentFixture(flags: 0x5, virtual: Self.base, memorySize: Self.page)
        ]) { image in
            // Nothing in the archive backs a page of zeros, and a frame of its own
            // is what makes it writable later without touching the initrd.
            #expect(image.shareablePages(of: 0) == 0)
            #expect(image.pageCount(of: 0) == 1)
        }
    }


    @Test("a segment whose file bytes stop short splits into an aliased run and a private remainder")
    func partialFileSizeSplitsTheSegment() {
        withImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(Self.page)
            )
        ]) { image in
            var shared: UInt64 = 0
            let declined = declinedTails { shared = image.shareablePages(of: 0) }

            // One page of file bytes and one of zero fill: the loader registers the
            // first `.fileBacked` and the rest `.anonymous`, which is two VMAs.
            #expect(shared == 1)
            #expect(image.pageCount(of: 0) - shared == 1)

            // p_filesz lands on a page boundary, so there is no tail to judge.
            #expect(declined == 0)
        }
    }


    @Test("a run that would reach past the end of the initrd is refused")
    func runPastTheArchiveIsRefused() {
        withImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            let firstPageEnd = image.residentBase + image.fileOffset(of: 0) + Self.page

            // The filesystem already handed out a base inside the window, so this
            // is the second half of the bound: one page fits, the run does not.
            image.stageInitrdEnd(firstPageEnd)
            #expect(image.shareablePages(of: 0) == 0)

            // The window is the only thing that changed, which the restored one says.
            // Asked twice on purpose, which is safe here: p_filesz lands on a page
            // boundary, so neither call can reach the tail counter.
            image.stageInitrdEnd(image.initrdEnd)
            #expect(image.shareablePages(of: 0) == 2)
        }
    }


    // MARK: - What the loader left behind

    @Test("an aliased segment is one file-backed region whose every page is an archive page")
    func aliasedSegmentOwnsNothing() {
        withLoadedImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            #expect(isSuccess(image.result), verdict(image.result))

            // One region for the whole segment, and `.fileBacked` is what tells
            // teardown to drop the translations and free nothing.
            #expect(image.regions.count == 1)
            #expect(image.regions.first?.start   == Self.base)
            #expect(image.regions.first?.end     == Self.base + 2 * Self.page)
            #expect(image.regions.first?.backing == .fileBacked)

            // Read-execute and no `.write`: a writable alias of a reserved frame has
            // no owner to release it, which is why the gate refuses one.
            #expect(image.regions.first?.permissions.contains(.execute) == true)
            #expect(image.regions.first?.permissions.contains(.write)   == false)

            // The translations are the archive's own bytes, consecutively, and not a
            // frame the allocator issued.
            let offset = image.fileOffset(of: 0)
            #expect(image.translate(Self.base)             == image.residentBase + offset)
            #expect(image.translate(Self.base + Self.page) == image.residentBase + offset + Self.page)
            #expect(image.translate(Self.base).map(image.isInsideArchive) == true)
            #expect(image.translate(Self.base).map(image.isPrivateFrame)  == false)

            // And what a process would read there is the file.
            #expect(image.byte(at: Self.base)                  == 0xAA)
            #expect(image.byte(at: Self.base + 2 * Self.page - 1) == 0xAA)
        }
    }


    @Test("a segment whose file bytes stop short becomes an aliased region and a private one")
    func splitSegmentRegistersTwoRegions() {
        withLoadedImage([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(Self.page)
            )
        ]) { image in
            #expect(isSuccess(image.result), verdict(image.result))

            // Two regions and not one: the zero-fill page is this address space's,
            // and a `.fileBacked` region covering it would leak the distinction.
            #expect(image.regions.count == 2)
            #expect(image.regions.first?.backing == .fileBacked)
            #expect(image.regions.first?.end     == Self.base + Self.page)
            #expect(image.regions.last?.backing  == .anonymous)
            #expect(image.regions.last?.start    == Self.base + Self.page)
            #expect(image.regions.last?.end      == Self.base + 2 * Self.page)

            #expect(image.translate(Self.base).map(image.isInsideArchive)             == true)
            #expect(image.translate(Self.base + Self.page).map(image.isPrivateFrame)  == true)

            // The private page is zero fill, which is what `p_memsz` past `p_filesz`
            // asked for, and the aliased one carries the file.
            #expect(image.byte(at: Self.base)             == 0xAA)
            #expect(image.byte(at: Self.base + Self.page) == 0)
        }
    }


    @Test("the byte that refused a tail page never reaches the address space")
    func refusedTailByteStaysInTheArchive() {
        var padding = zeros(Self.page - 100)
        padding[0]  = 0xFF

        withLoadedImage([Self.segmentWithTail(padding: padding)]) { image in
            #expect(isSuccess(image.result), verdict(image.result))

            // The full page keeps its alias, the tail is copied into a frame of this
            // address space's own.
            #expect(image.regions.count == 2)
            #expect(image.regions.first?.backing == .fileBacked)
            #expect(image.regions.last?.backing  == .anonymous)
            #expect(image.translate(Self.base).map(image.isInsideArchive)            == true)
            #expect(image.translate(Self.base + Self.page).map(image.isPrivateFrame) == true)

            // The 100 bytes the segment does have are there, and the 0xFF that
            // follows them in the archive is not: the copy stops at p_filesz.
            #expect(image.byte(at: Self.base + Self.page + 99)  == 0xAA)
            #expect(image.byte(at: Self.base + Self.page + 100) == 0)
        }
    }


    @Test("a writable segment is copied into frames of its own")
    func writableSegmentGetsPrivateFrames() {
        withLoadedImage([
            ELFSegmentFixture(
                flags     : 0x6,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : filled(2 * Self.page)
            )
        ]) { image in
            #expect(isSuccess(image.result), verdict(image.result))

            // Registered page by page and merged back into one anonymous region.
            #expect(image.regions.count == 1)
            #expect(image.regions.first?.backing == .anonymous)
            #expect(image.regions.first?.permissions.contains(.write) == true)

            #expect(image.translate(Self.base).map(image.isPrivateFrame)             == true)
            #expect(image.translate(Self.base + Self.page).map(image.isPrivateFrame) == true)

            // The copy pass ran: the frames carry the file's bytes and not zeros.
            #expect(image.byte(at: Self.base)                     == 0xAA)
            #expect(image.byte(at: Self.base + 2 * Self.page - 1) == 0xAA)
        }
    }


    @Test("an unaligned archive loads the same image into private frames")
    func unalignedArchiveLoadsThroughTheCopyPath() {
        withLoadedImage(
            [
                ELFSegmentFixture(
                    flags     : 0x5,
                    virtual   : Self.base,
                    memorySize: 2 * Self.page,
                    payload   : filled(2 * Self.page)
                )
            ],
            layout: .unaligned
        ) { image in
            #expect(isSuccess(image.result), verdict(image.result))

            // The old loader's behaviour, unchanged: nothing is aliased, one
            // anonymous region covers the image, and the bytes still arrive.
            #expect(image.regions.count == 1)
            #expect(image.regions.first?.backing == .anonymous)
            #expect(image.translate(Self.base).map(image.isPrivateFrame)             == true)
            #expect(image.translate(Self.base + Self.page).map(image.isPrivateFrame) == true)
            #expect(image.byte(at: Self.base)                     == 0xAA)
            #expect(image.byte(at: Self.base + 2 * Self.page - 1) == 0xAA)
        }
    }


    // MARK: - The loader over a page manager that cannot allocate

    @Test("the loader counts the tail page the archive did not pad")
    func loaderCountsDeclinedTails() {
        var padding = zeros(Self.page - 100)

        let padded   = loadCountingDeclines([Self.segmentWithTail(padding: padding)])
        padding[0]   = 0xFF
        let unpadded = loadCountingDeclines([Self.segmentWithTail(padding: padding)])

        // The archives differ in one byte, past p_filesz, which only a loader that
        // asked about the member the filesystem opened could have read.
        #expect(padded.declined   == 0)
        #expect(unpadded.declined == 1)

        // Both reach the mapping pass and both die in the staged page manager, so
        // the counter is the whole difference the host can see.
        #expect(isAllocationFailure(padded.result))
        #expect(isAllocationFailure(unpadded.result))
    }


    @Test("an unaligned archive keeps the loader on the copy path")
    func unalignedArchiveCopiesEverything() {
        var padding = zeros(Self.page - 100)
        padding[0]  = 0xFF

        let outcome = loadCountingDeclines(
            [Self.segmentWithTail(padding: padding)],
            layout: .unaligned
        )

        // The default layout is the one every other ELF fixture is staged with, so
        // this pins the assumption they rest on: sharing is declined before the tail
        // is even looked at, and the loader copies the image as it always did.
        #expect(outcome.declined == 0)
        #expect(isAllocationFailure(outcome.result))
    }


    // MARK: - Fixtures

    /// A non-writable segment whose file bytes end 100 bytes into its second page,
    /// with `padding` written after them and left out of `p_filesz`.
    ///
    /// The shape of a real text segment: whole pages, then a partial one whose rest
    /// the toolchain is expected to have zeroed.
    private static func segmentWithTail(padding: [UInt8]) -> ELFSegmentFixture {
        ELFSegmentFixture(
            flags     : 0x5,
            virtual   : base,
            memorySize: 2 * page,
            payload   : [UInt8](repeating: 0xAA, count: Int(page) + 100),
            trailing  : padding
        )
    }


    private func filled(_ count: UInt64, _ value: UInt8 = 0xAA) -> [UInt8] {
        [UInt8](repeating: value, count: Int(count))
    }


    private func zeros(_ count: UInt64) -> [UInt8] {
        [UInt8](repeating: 0, count: Int(count))
    }


    /// Stages `segments` as an initrd member and runs `body` over the gate's inputs.
    private func withImage(
        _ segments     : [ELFSegmentFixture],
        layout         : ELFFixtureLayout = .shareable,
        followedBy next: [UInt8]? = nil,
        _ body         : (StagedELFImage) -> Void
    ) {
        // Called outside `#expect`: the macro rewrites a call into a closure over
        // its arguments, which a non-escaping `body` cannot be passed through.
        let staged = withStagedELFImage(segments, layout: layout, followedBy: next, body)

        #expect(staged, "the fixture archive did not open")
    }


    /// Stages `segments` and runs the whole loader over a live page manager, then
    /// reads back the address space it built.
    private func withLoadedImage(
        _ segments: [ELFSegmentFixture],
        layout    : ELFFixtureLayout = .shareable,
        _ body    : (LoadedELFImage) -> Void
    ) {
        let loaded = withLoadedELFImage(segments, layout: layout, body)

        #expect(loaded, "the fixture archive did not open")
    }


    // MARK: - Observables

    /// Tail pages `ImageSharing` refused while `body` ran.
    ///
    /// A delta and not the counter: it is a boot-long total that every suite in the
    /// run adds to, and `shareablePageCount` is documented to be asked once per
    /// segment per load, which is what makes the delta this fixture's own.
    private func declinedTails(_ body: () -> Void) -> UInt64 {
        let before = ImageSharing.declinedTailPages
        body()

        return ImageSharing.declinedTailPages - before
    }


    /// One real `loadSegments` run, with the tails it refused along the way.
    private func loadCountingDeclines(
        _ segments: [ELFSegmentFixture],
        layout    : ELFFixtureLayout = .shareable
    ) -> (result: Result<LoadedELF, ElfError>, declined: UInt64) {

        var outcome: ELFLoadOutcome?
        let declined = declinedTails {
            outcome = loadELFFixture(segments, layout: layout)
        }

        guard let outcome else {
            Issue.record("the fixture archive did not open")

            return (.failure(.malformedLayout), declined)
        }

        return (outcome.result, declined)
    }


    /// The loader got past the header and W^X passes and only then ran out of
    /// frames, which is as far as a host process can follow it.
    private func expectReachesMappingPass(
        _ segments: [ELFSegmentFixture],
        layout    : ELFFixtureLayout
    ) {
        let outcome = loadCountingDeclines(segments, layout: layout)

        #expect(isAllocationFailure(outcome.result), verdict(outcome.result))
    }


    private func isSuccess(_ result: Result<LoadedELF, ElfError>) -> Bool {
        if case .success = result { return true }

        return false
    }


    private func isAllocationFailure(_ result: Result<LoadedELF, ElfError>) -> Bool {
        if case .failure(.allocationFailed) = result { return true }

        return false
    }


    private func verdict(_ result: Result<LoadedELF, ElfError>) -> Comment {
        switch result {
            case .success(let image):
                Comment(rawValue: "accepted: \(image.loadBase)..<\(image.loadEnd)")

            case .failure(let error):
                Comment(rawValue: String(describing: error))
        }
    }
}


}
