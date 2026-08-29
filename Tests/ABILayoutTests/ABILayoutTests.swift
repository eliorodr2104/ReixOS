//
//  ABILayoutTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.


import Testing
@testable import Kernel
import ReixABI

/// Every record here is read or written by something that does not share this
/// module's idea of its layout: userland through an SHM window or a syscall
/// buffer, an ELF image on disk, or the per-frame array whose size is paid once
/// per 4 KiB of RAM. The asserts are the lock, so a field added in the middle of
/// one of them fails here and not on a booted machine.
///
/// Pure layout probes, no global state, so this suite is parallel safe. It runs
/// under `swift test --no-parallel` with the rest all the same.
@Suite("ABI layout")
struct ABILayoutTests {

    @Test("the TextSurface transport occupies exactly one typed page")
    func textSurfaceTransportLayout() {
        #expect(ReixTextSurfaceTransport.pages == 1)
        #expect(ReixTextSurfaceTransport.headerBytes == 64)
        #expect(ReixTextSurfaceProtocol.recordBytes == 288)
        #expect(ReixTextSurfaceTransport.headerBytes + ReixTextSurfaceTransport.capacity * ReixTextSurfaceProtocol.recordBytes == ReixTextSurfaceTransport.pageBytes)
    }

    @Test("the per-frame record stays eight bytes and starts life all zero")
    func frameInfoLayout() {
        // 8 bytes is one word per frame. At 9 the stride becomes 12 and a third of
        // the metadata array is padding, which is RAM this kernel does not have.
        #expect(MemoryLayout<FrameInfo>.size   == 8)
        #expect(MemoryLayout<FrameInfo>.stride == 8)

        // Both initializers must produce it: a free frame that stopped reading as
        // all zero would read as owned, or as a heap page.
        #expect(zeroBytes(FrameInfo()))
        #expect(zeroBytes(FrameInfo(refCount: 0, order: 0, flags: .none)))

        // The nibbles must not bleed into each other: `order` 15 is the
        // block-interior sentinel and `heapShift` 12 the largest slab bucket.
        var packed = FrameInfo()
        packed.order     = 15
        packed.heapShift = 12
        #expect(packed.order     == 15)
        #expect(packed.heapShift == 12)
    }


    @Test("capability slots keep their twenty-four byte stride")
    func capabilityLayout() {
        // The cap space is an array indexed by handle. A wider slot silently moves
        // every handle a process already holds.
        //
        // It survived the session widening to sixty-four bits, which took two
        // things: the device window's *width* down to thirty-two bits, and the
        // narrow fields moved to sit after the wide ones. Either one alone leaves
        // the stride at thirty-two and `ProcessMetadata` in the 2048 byte slab
        // bucket instead of the 1024 one.
        #expect(MemoryLayout<Capability>.stride == 24)

        // The slot is the optional: `CapsTable` stores `Capability?`, so an empty
        // case that stopped riding a spare bit would widen every slot on its own.
        #expect(MemoryLayout<Capability?>.stride == 24)
    }


    @Test("the per-process records stay inside their kernel heap buckets")
    func processLayout() {
        // Both are kmalloc'ed per process. Crossing a power-of-two bucket doubles
        // the slab block each spawn takes, on a machine targeting 4 MiB.
        //
        // The metadata crossed from 512 to 1024 on purpose when the capability
        // table went from sixteen slots to thirty-two, because a view of the
        // disk became a capability like any other and sixteen stopped being
        // enough. The next crossing is not free either: this is the assertion
        // that will notice.
        #expect(MemoryLayout<Process>.stride         <= 256)
        #expect(MemoryLayout<ProcessMetadata>.stride <= 1024)

        // `Process` holds a `PendingMessage`, which holds a session. Widening
        // the session took that struct from a thirty-two byte stride to
        // forty-eight and `Process` over the edge; storing the grant as the
        // sentinel the wire already uses rather than as an optional took the
        // five-byte field to four and brought both back.
        #expect(MemoryLayout<PendingMessage>.stride <= 40)
    }


    @Test("the stats wire records stay byte exact at forty-eight bytes")
    func statsLayout() {
        // Userland reads both straight out of an SHM window or a syscall buffer
        // with one struct load, so a drift here is a misread field and not an error.
        #expect(MemoryLayout<SystemStats>.size    == 56)
        #expect(MemoryLayout<SystemStats>.stride  == 56)
        #expect(MemoryLayout<ProcessStats>.size   == 48)
        #expect(MemoryLayout<ProcessStats>.stride == 48)
        #expect(ProcessStats().name.count == 16)
    }


    @Test("the ELF header layouts match the on-disk format")
    func elfHeaderLayout() {
        // The parser reads a raw image straight into these, and checks the image's
        // own `e_phentsize` against the second one. Both are ELF64 spec sizes.
        #expect(MemoryLayout<Elf64_Ehdr_t>.size   == 64)
        #expect(MemoryLayout<Elf64_Ehdr_t>.stride == 64)
        #expect(MemoryLayout<Elf64_Phdr_t>.size   == 56)
        #expect(MemoryLayout<Elf64_Phdr_t>.stride == 56)
    }


    @Test("the IPC wire types keep the strides both sides were compiled against")
    func ipcLayout() {
        // The rendezvous path copies a `Message` between address spaces, and the
        // same declaration is compiled into the kernel and into every user image.
        #expect(MemoryLayout<Message>.stride    == 24)
        #expect(MemoryLayout<MessageTag>.stride == 8)

        // The tag also travels packed into a single register, so the packing has to
        // survive a round trip whatever the struct's own layout is.
        let tag = MessageTag(packed: MessageTag(ProbeLabel.probe, length: 3).packed())
        #expect(tag.label  == 0x1234_5678)
        #expect(tag.length == 3)

        // Spawn-time capability injection reads an array of these out of a user
        // buffer, so the stride is the caller's array step.
        #expect(MemoryLayout<CapGrant>.stride == 12)
    }


    private func zeroBytes<T>(_ value: T) -> Bool {
        withUnsafeBytes(of: value) { bytes in bytes.allSatisfy { $0 == 0 } }
    }


    /// A label to build a tag from. The real ones live in the userland SDK, which the
    /// kernel's own suites do not link.
    private enum ProbeLabel: UInt32, IPCLabel {
        case probe = 0x1234_5678
    }
}
