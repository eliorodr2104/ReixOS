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

    private struct GuardedTrapFrame {
        var before: UInt64 = 0x1122_3344_5566_7788
        var frame = AArch64TrapFrame()
        var after: UInt64 = 0x8877_6655_4433_2211
    }

    @Test("the AArch64 trap frame matches the exception assembly layout")
    func trapFrameLayout() {
        // GPR and exception-register offsets are intentionally unchanged. The
        // complete FP/SIMD image is appended so existing diagnostics keep
        // decoding the same words while ContextSaving.S gains the missing state.
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.x0)    == 0)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.x30)  == 240)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.elr)  == 248)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.spsr) == 256)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.esr)  == 264)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.far)  == 272)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.spel0) == 280)

        let qWords: [WritableKeyPath<AArch64TrapFrame, UInt64>] = [
            \AArch64TrapFrame.q0Low,   \AArch64TrapFrame.q0High,
            \AArch64TrapFrame.q1Low,   \AArch64TrapFrame.q1High,
            \AArch64TrapFrame.q2Low,   \AArch64TrapFrame.q2High,
            \AArch64TrapFrame.q3Low,   \AArch64TrapFrame.q3High,
            \AArch64TrapFrame.q4Low,   \AArch64TrapFrame.q4High,
            \AArch64TrapFrame.q5Low,   \AArch64TrapFrame.q5High,
            \AArch64TrapFrame.q6Low,   \AArch64TrapFrame.q6High,
            \AArch64TrapFrame.q7Low,   \AArch64TrapFrame.q7High,
            \AArch64TrapFrame.q8Low,   \AArch64TrapFrame.q8High,
            \AArch64TrapFrame.q9Low,   \AArch64TrapFrame.q9High,
            \AArch64TrapFrame.q10Low, \AArch64TrapFrame.q10High,
            \AArch64TrapFrame.q11Low, \AArch64TrapFrame.q11High,
            \AArch64TrapFrame.q12Low, \AArch64TrapFrame.q12High,
            \AArch64TrapFrame.q13Low, \AArch64TrapFrame.q13High,
            \AArch64TrapFrame.q14Low, \AArch64TrapFrame.q14High,
            \AArch64TrapFrame.q15Low, \AArch64TrapFrame.q15High,
            \AArch64TrapFrame.q16Low, \AArch64TrapFrame.q16High,
            \AArch64TrapFrame.q17Low, \AArch64TrapFrame.q17High,
            \AArch64TrapFrame.q18Low, \AArch64TrapFrame.q18High,
            \AArch64TrapFrame.q19Low, \AArch64TrapFrame.q19High,
            \AArch64TrapFrame.q20Low, \AArch64TrapFrame.q20High,
            \AArch64TrapFrame.q21Low, \AArch64TrapFrame.q21High,
            \AArch64TrapFrame.q22Low, \AArch64TrapFrame.q22High,
            \AArch64TrapFrame.q23Low, \AArch64TrapFrame.q23High,
            \AArch64TrapFrame.q24Low, \AArch64TrapFrame.q24High,
            \AArch64TrapFrame.q25Low, \AArch64TrapFrame.q25High,
            \AArch64TrapFrame.q26Low, \AArch64TrapFrame.q26High,
            \AArch64TrapFrame.q27Low, \AArch64TrapFrame.q27High,
            \AArch64TrapFrame.q28Low, \AArch64TrapFrame.q28High,
            \AArch64TrapFrame.q29Low, \AArch64TrapFrame.q29High,
            \AArch64TrapFrame.q30Low, \AArch64TrapFrame.q30High,
            \AArch64TrapFrame.q31Low, \AArch64TrapFrame.q31High,
        ]

        for (index, keyPath) in qWords.enumerated() {
            #expect(MemoryLayout<AArch64TrapFrame>.offset(of: keyPath) == 288 + index * 8)
        }

        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.fpcr) == 800)
        #expect(MemoryLayout<AArch64TrapFrame>.offset(of: \AArch64TrapFrame.fpsr) == 808)
        #expect(MemoryLayout<AArch64TrapFrame>.size   == 816)
        #expect(MemoryLayout<AArch64TrapFrame>.stride == 816)

        // A context that has never run must reveal no register state from the
        // kernel, firmware, or the slab block's previous owner.
        var fresh = AArch64TrapFrame()
        #expect(withUnsafeBytes(of: &fresh) { $0.allSatisfy { $0 == 0 } })

        // The fixed-width copy is the switch/split mechanism. Give every word
        // a distinct nonzero value so truncation at any GPR, system register,
        // vector half, or FP control word is observable.
        withUnsafeMutableBytes(of: &fresh) { bytes in
            for index in 0..<(bytes.count / MemoryLayout<UInt64>.size) {
                bytes.storeBytes(
                    of          : 0xA500_0000_0000_0000 | UInt64(index + 1),
                    toByteOffset: index * MemoryLayout<UInt64>.size,
                    as          : UInt64.self
                )
            }
        }
        let expected = withUnsafeBytes(of: &fresh) { Array($0) }

        var guarded = GuardedTrapFrame()
        withUnsafePointer(to: &fresh) { source in
            withUnsafeMutablePointer(to: &guarded.frame) { destination in
                AArch64TrapFrame.copy(from: source, to: destination)
            }
        }
        #expect(withUnsafeBytes(of: &guarded.frame) { Array($0) } == expected)
        #expect(withUnsafeBytes(of: &fresh) { Array($0) } == expected)
        #expect(guarded.before == 0x1122_3344_5566_7788)
        #expect(guarded.after  == 0x8877_6655_4433_2211)

        // The helper explicitly accepts an identical source/destination; it
        // must be a no-op because scheduler fast paths can converge on one
        // process context.
        withUnsafeMutablePointer(to: &guarded.frame) { frame in
            AArch64TrapFrame.copy(from: UnsafePointer(frame), to: frame)
        }
        #expect(withUnsafeBytes(of: &guarded.frame) { Array($0) } == expected)
        #expect(guarded.before == 0x1122_3344_5566_7788)
        #expect(guarded.after  == 0x8877_6655_4433_2211)
    }

    @Test("panic reports borrow trap frames instead of embedding register images")
    func panicReportLayout() {
        // `Arch.CPU.panic` is inlined into allocation, VM, IPC, and scheduler
        // guards. Keeping the frame behind a pointer prevents those callers
        // from reserving an 816-byte optional payload on every normal path.
        #expect(MemoryLayout<PanicReport>.stride <= 64)
    }

    @Test("the TextSurface transport holds one maximum snapshot atomically")
    func textSurfaceTransportLayout() {
        #expect(ReixTextSurfaceTransport.pages == 3)
        #expect(ReixTextSurfaceTransport.headerBytes == 64)
        #expect(ReixTextSurfaceProtocol.recordBytes == 288)
        let used = ReixTextSurfaceTransport.headerBytes
            + ReixTextSurfaceTransport.capacity * ReixTextSurfaceProtocol.recordBytes
        #expect(used <= ReixTextSurfaceTransport.regionBytes)
        #expect(ReixTextSurfaceTransport.regionBytes - used < ReixTextSurfaceProtocol.recordBytes)
        #expect(ReixTextSurfaceTransport.maximumFrameRecords <= ReixTextSurfaceTransport.capacity)
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
