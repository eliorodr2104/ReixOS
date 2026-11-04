//
//  CodePublicationTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport
import KernelHostShims

/// The loader publishes an image's code as one batch, after the last byte of it
/// has landed.
///
/// The loader maps first and copies after, so a page published when it was
/// mapped was published before its bytes existed: the clean pushed zeros, and
/// the copy that followed stayed in the data cache, where an instruction fetch
/// on hardware whose caches are not coherent does not look. QEMU keeps no
/// instruction cache and could not tell. The recorder can: every staged range
/// is in it, with its frame and its size, and so is the one completion.
///
/// `.serialized`, and the run needs `--no-parallel`: the recorder, the loaded
/// cache type and every global `withLoadedELFImage` moves.
extension KernelPolicyTestRoot {
@Suite("ELF code publication", .serialized)
struct CodePublicationTests {

    private static let base = UserSpaceLayout.elfBaseTypical
    private static let page = UserSpaceLayout.pageSize

    /// Every cache operation the load issued, in order; the page-table barriers
    /// of the fixture's own staging are left out.
    private static func cacheCalls() -> [MMUCall] {
        mmuCalls().filter { [.cleanPoU, .icacheLines, .icacheAll, .stream].contains($0.op) }
    }


    @Test("copied code is published once, after the copy has written it")
    func copiedCodeIsPublishedAfterTheCopy() {
        load([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : [UInt8](repeating: 0xAA, count: Int(2 * Self.page))
            )
        ], layout: .unaligned) { image in
            guard let first  = image.translate(Self.base),
                  let second = image.translate(Self.base + Self.page)
            else { Issue.record("the image was not mapped"); return }

            // Each page staged as it was mapped, then again once the copy pass has
            // written it, and the one completion after the last of them.
            #expect(Self.ranges() == [
                Range(op: .cleanPoU, arg: first,  size: Self.page),
                Range(op: .cleanPoU, arg: second, size: Self.page),
                Range(op: .cleanPoU, arg: first,  size: Self.page),
                Range(op: .cleanPoU, arg: second, size: Self.page),
                Range(op: .icacheAll, arg: 0, size: 0)
            ])
            #expect(Self.cacheCalls().allSatisfy { $0.op != .cleanPoU || $0.line == 64 })
            #expect(image.byte(at: Self.base) == 0xAA)
        }
    }


    @Test("an aliased text segment is staged where it lies and published once")
    func aliasedCodeIsPublishedOnce() {
        load([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : [UInt8](repeating: 0xAA, count: Int(2 * Self.page))
            )
        ], layout: .shareable) { image in
            let archive = image.residentBase + image.fileOffset(of: 0)

            #expect(Self.ranges() == [
                Range(op: .cleanPoU, arg: archive,             size: Self.page),
                Range(op: .cleanPoU, arg: archive + Self.page, size: Self.page),
                Range(op: .icacheAll, arg: 0, size: 0)
            ])
        }
    }


    @Test("the tail of a text segment the archive could not share is published after its copy")
    func copiedTailIsPublishedAfterTheCopy() {
        var trailing = [UInt8](repeating: 0, count: Int(Self.page) - 100)
        trailing[0]  = 0xFF

        load([
            ELFSegmentFixture(
                flags     : 0x5,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : [UInt8](repeating: 0xAA, count: Int(Self.page) + 100),
                trailing  : trailing
            )
        ], layout: .shareable) { image in
            let archive = image.residentBase + image.fileOffset(of: 0)

            guard let tail = image.translate(Self.base + Self.page),
                  image.isPrivateFrame(tail)
            else { Issue.record("the tail was not given a frame of its own"); return }

            // The aliased page, the tail's zeros as it was mapped, the 100 bytes
            // the copy put there, and only then the completion.
            #expect(Self.ranges() == [
                Range(op: .cleanPoU, arg: archive, size: Self.page),
                Range(op: .cleanPoU, arg: tail,    size: Self.page),
                Range(op: .cleanPoU, arg: tail,    size: 100),
                Range(op: .icacheAll, arg: 0, size: 0)
            ])
            #expect(image.byte(at: Self.base + Self.page + 99) == 0xAA)
        }
    }


    @Test("an image with no code publishes nothing")
    func dataOnlyImagePublishesNothing() {
        load([
            ELFSegmentFixture(
                flags     : 0x6,
                virtual   : Self.base,
                memorySize: 2 * Self.page,
                payload   : [UInt8](repeating: 0xAA, count: Int(2 * Self.page))
            )
        ], layout: .unaligned) { _ in
            #expect(Self.cacheCalls().isEmpty)
        }
    }


    // MARK: - Fixture

    /// What a cache operation covered, without the descriptor column the
    /// fixture's staging leaves behind.
    private struct Range: Equatable {
        let op  : MMUOp
        let arg : UInt64
        let size: UInt64
    }

    private static func ranges() -> [Range] {
        cacheCalls().map { Range(op: $0.op, arg: $0.arg, size: $0.size) }
    }


    /// Loads `segments` under the Cortex-A53's cache type with the recorder
    /// running, and hands `body` the image once the load has succeeded.
    private func load(
        _ segments: [ELFSegmentFixture],
        layout    : ELFFixtureLayout,
        _ body    : (LoadedELFImage) -> Void
    ) {
        withCacheType(cortexA53CacheType) {
            mmu_trace_reset(nil)
            defer { mmu_trace_reset(nil) }

            let loaded = withLoadedELFImage(segments, layout: layout) { image in
                guard case .success = image.result else {
                    Issue.record("the image did not load: \(image.result)")
                    return
                }

                body(image)
            }

            #expect(loaded, "the fixture archive did not open")
        }
    }
}
}
