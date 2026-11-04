//
//  StackUsageTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

import Testing
@testable import Kernel

/// The high-water scan, over a buffer this suite poisons itself.
///
/// The linker-placed spans it reads on the machine do not exist on the host
/// (see `StackUsage.kernelSpan`), so the accessors are not what is testable
/// here. The scan is, and it is the part with a direction, a boundary and two
/// degenerate cases to get wrong.
@Suite("Stack usage scan")
struct StackUsageTests {

    /// Runs `body` over `words` poisoned 64-bit slots, handing it the span the
    /// scan takes and the buffer to dirty.
    private func withPoisonedStack(
        words: Int,
        _ body: (UnsafeMutableBufferPointer<UInt64>, UInt64, UInt64) -> Void
    ) {
        let buffer = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: words)
        defer { buffer.deallocate() }

        buffer.initialize(repeating: StackUsage.poison)

        let bottom = UInt64(UInt(bitPattern: buffer.baseAddress!))

        body(buffer, bottom, bottom + UInt64(words * 8))
    }

    @Test("an untouched span reports nothing used")
    func intact() {
        withPoisonedStack(words: 64) { _, bottom, top in
            #expect(StackUsage.used(from: bottom, to: top) == 0)
        }
    }

    @Test("the figure is measured down from the top, not up from the deepest write")
    func depthFromTop() {
        withPoisonedStack(words: 64) { buffer, bottom, top in
            // One word dirtied 10 slots below the top: 80 bytes are in use, even
            // though 424 bytes of poison sit under it and the stack never filled.
            buffer[64 - 10] = 0xDEAD_BEEF

            #expect(StackUsage.used(from: bottom, to: top) == 80)
        }
    }

    @Test("the deepest write wins, and shallower ones above it do not add up")
    func deepestWins() {
        withPoisonedStack(words: 64) { buffer, bottom, top in
            buffer[64 - 2]  = 1
            buffer[64 - 20] = 1
            buffer[64 - 9]  = 1

            #expect(StackUsage.used(from: bottom, to: top) == 160)
        }
    }

    @Test("a fully consumed span reports its whole size")
    func exhausted() {
        withPoisonedStack(words: 8) { buffer, bottom, top in
            buffer[0] = 1

            #expect(StackUsage.used(from: bottom, to: top) == 64)
        }
    }

    @Test("a degenerate or misaligned span is refused rather than dereferenced")
    func refusals() {
        withPoisonedStack(words: 8) { _, bottom, top in
            #expect(StackUsage.used(from: top,      to: bottom) == 0) // inverted
            #expect(StackUsage.used(from: bottom,   to: bottom) == 0) // empty
            #expect(StackUsage.used(from: bottom + 1, to: top)  == 0) // misaligned
        }

        // The host stand-in for a span that does not exist. Reading it would be
        // a load from a null pointer, which is the whole reason for the guard.
        #expect(StackUsage.used(from: 0, to: 0) == 0)
    }
}
