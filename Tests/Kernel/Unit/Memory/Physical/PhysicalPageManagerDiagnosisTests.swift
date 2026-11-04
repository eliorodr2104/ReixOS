//
//  PhysicalPageManagerDiagnosisTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// `PhysicalPageManager.diagnose`: one test per answer it can give, one that it
/// changes nothing, and one that it agrees with `free` about every frame.
///
/// Every state is staged on a live manager over a host arena, either by the
/// manager's own `alloc` and `free` or by writing a `FrameInfo` straight into
/// the metadata array, which is how the books would look if something had
/// corrupted them.
///
/// No global state, so this suite is parallel safe on its own. It runs under
/// `swift test --no-parallel` with the rest all the same.
@Suite("Physical page manager diagnosis")
struct PhysicalPageManagerDiagnosisTests {

    private static let page = UInt64(4096)


    /// A live manager over `pages` frames, every one of them donated.
    private func withManager(
        pages : Int = 32,
        _ body: (HostRAM) -> Void
    ) {
        withHostRAM(pages: pages) { ram in
            ram.installLiveManager(reservePages: 0)
            #expect(ram.donateAll())

            body(ram)
        }
    }


    private func diagnose(
        _ ram    : HostRAM,
        _ address: PhysicalAddress,
        order    : UInt8
    ) -> PhysicalBlockState {
        ram.ppm.pointee.diagnose(address, order: order)
    }


    // MARK: - One test per answer

    @Test("a live head of the order asked about is live")
    func live() throws {
        try withManagerThrowing { ram in
            let block = try ram.ppm.pointee.alloc(Int(Self.page) * 4)

            #expect(diagnose(ram, block.address, order: 2) == .live)
        }
    }


    @Test("a live head of another order names the order the books hold")
    func orderMismatch() throws {
        try withManagerThrowing { ram in
            let block = try ram.ppm.pointee.alloc(Int(Self.page) * 4)

            #expect(diagnose(ram, block.address, order: 1) == .orderMismatch(recorded: 2))
            #expect(diagnose(ram, block.address, order: 3) == .orderMismatch(recorded: 2))
        }
    }


    @Test("every frame after a block's head is its interior")
    func interior() throws {
        try withManagerThrowing { ram in
            let block = try ram.ppm.pointee.alloc(Int(Self.page) * 4)

            for frame in 1..<4 {
                #expect(diagnose(ram, block.address + UInt64(frame) * Self.page, order: 0) == .interior)
            }
        }
    }


    @Test("a block given back, and a frame never handed out, are free")
    func free() throws {
        try withManagerThrowing { ram in
            let block   = try ram.ppm.pointee.alloc(Int(Self.page) * 4)
            let address = block.address

            try ram.ppm.pointee.free(block)

            #expect(diagnose(ram, address, order: 2) == .free)
            #expect(diagnose(ram, address + Self.page, order: 0) == .free)
        }
    }


    @Test("a frame withheld at boot is reserved")
    func reserved() {
        withManager { ram in
            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .reserved), at: ram.page(5))

            #expect(diagnose(ram, ram.page(5), order: 0) == .reserved)
        }
    }


    @Test("a live head carrying .kernel is the kernel's")
    func kernelOwned() throws {
        try withManagerThrowing { ram in
            let block = try ram.ppm.pointee.alloc(Int(Self.page), flag: .kernel)

            #expect(diagnose(ram, block.address, order: 0) == .kernelOwned)
        }
    }


    /// Each shape of books that contradict themselves, every one of which
    /// `validatedLiveBlock` refuses for a reason other than the four above.
    @Test("books that contradict themselves are damaged", arguments: [
        "owned head with no reference",
        "references on a frame nobody owns",
        "head not aligned to its order",
        "extent past the end of RAM",
    ])
    func damaged(shape: String) {
        withManager(pages: 32) { ram in
            let staged: (FrameInfo, PhysicalAddress, UInt8) = switch shape {
                case "owned head with no reference":
                    (FrameInfo(refCount: 0, order: 0, flags: .allocatorOwned), ram.page(4), 0)
                case "references on a frame nobody owns":
                    (FrameInfo(refCount: 1, order: 0, flags: .none), ram.page(4), 0)
                case "head not aligned to its order":
                    (FrameInfo(refCount: 1, order: 2, flags: .allocatorOwned), ram.page(6), 2)
                default:
                    (FrameInfo(refCount: 1, order: 6, flags: .allocatorOwned), ram.page(0), 6)
            }

            ram.setFrame(staged.0, at: staged.1)

            #expect(diagnose(ram, staged.1, order: staged.2) == .damaged)
        }
    }


    @Test("an address the books do not describe is outside RAM")
    func outsideRAM() {
        withManager { ram in
            #expect(diagnose(ram, ram.base - Self.page, order: 0) == .outsideRAM)
            #expect(diagnose(ram, ram.end,              order: 0) == .outsideRAM)
            #expect(diagnose(ram, ram.base + 1,         order: 0) == .outsideRAM)

            // And a manager whose metadata is not there to read.
            let metadata = ram.ppm.pointee.framesMetadata
            ram.ppm.pointee.framesMetadata = nil
            defer { ram.ppm.pointee.framesMetadata = metadata }

            #expect(diagnose(ram, ram.base, order: 0) == .outsideRAM)
        }
    }


    // MARK: - What it promises across every answer

    /// It runs on books that may be wrong, so the evidence it reads has to be
    /// the same evidence afterwards, byte for byte, buddy included.
    @Test("a diagnosis changes nothing, whatever it finds")
    func readOnly() throws {
        try withManagerThrowing { ram in
            let live   = try ram.ppm.pointee.alloc(Int(Self.page) * 4)
            let kernel = try ram.ppm.pointee.alloc(Int(Self.page), flag: .kernel)
            let freed  = try ram.ppm.pointee.alloc(Int(Self.page) * 2)
            let gone   = freed.address

            try ram.ppm.pointee.free(freed)

            // Frames this test holds, so the two rewritten below sit inside no
            // block anybody else's books describe.
            let reserved = try ram.ppm.pointee.alloc(Int(Self.page)).address
            let damaged  = try ram.ppm.pointee.alloc(Int(Self.page)).address

            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .reserved), at: reserved)
            ram.setFrame(FrameInfo(refCount: 0, order: 0, flags: .allocatorOwned), at: damaged)

            let probes: [(PhysicalAddress, UInt8)] = [
                (live.address, 2), (live.address, 1), (live.address + Self.page, 0),
                (kernel.address, 0), (gone, 1), (reserved, 0), (damaged, 0),
                (ram.end, 0), (ram.base + 1, 0),
            ]

            let before = ram.pmmStateSnapshot()

            for (address, order) in probes { _ = diagnose(ram, address, order: order) }

            #expect(ram.pmmStateSnapshot() == before)
        }
    }


    /// The two read the same books in the same order, so they cannot disagree:
    /// `free` takes exactly what the diagnosis calls live.
    @Test("free takes what the diagnosis calls live and refuses everything else")
    func agreesWithFree() throws {
        try withManagerThrowing { ram in
            let live   = try ram.ppm.pointee.alloc(Int(Self.page) * 4)
            let kernel = try ram.ppm.pointee.alloc(Int(Self.page), flag: .kernel)
            let freed  = try ram.ppm.pointee.alloc(Int(Self.page) * 2)
            let gone   = freed.address

            try ram.ppm.pointee.free(freed)

            // Frames this test holds, so the two rewritten below sit inside no
            // block anybody else's books describe.
            let reserved = try ram.ppm.pointee.alloc(Int(Self.page)).address
            let damaged  = try ram.ppm.pointee.alloc(Int(Self.page)).address

            ram.setFrame(FrameInfo(refCount: 1, order: 0, flags: .reserved), at: reserved)
            ram.setFrame(FrameInfo(refCount: 0, order: 0, flags: .allocatorOwned), at: damaged)

            let refused: [(PhysicalAddress, UInt8)] = [
                (live.address, 1), (live.address + Self.page, 0), (kernel.address, 0),
                (gone, 1), (reserved, 0), (damaged, 0), (ram.end, 0),
            ]

            for (address, order) in refused {
                #expect(diagnose(ram, address, order: order) != .live)
                #expect((try? ram.ppm.pointee.free(PhysicalPage(address: address, order: order))) == nil)
            }

            #expect(diagnose(ram, live.address, order: 2) == .live)
            #expect((try? ram.ppm.pointee.free(PhysicalPage(address: live.address, order: 2))) != nil)
        }
    }


    // MARK: - Fixture

    private func withManagerThrowing(_ body: (HostRAM) throws -> Void) throws {
        var failure: (any Error)? = nil

        withManager { ram in
            do { try body(ram) } catch { failure = error }
        }

        if let failure { throw failure }
    }
}
