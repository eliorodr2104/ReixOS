//
//  RawBytesTests.swift
//  ReixOS
//

import Testing
@testable import ReixABI

/// The bulk moves under every `memcpy`, `memset` and `memmove`, checked byte by
/// byte against a plain loop at every alignment the code branches on.
///
/// Two things are asserted besides the bytes. The guards either side of the range
/// stay intact, because a move that runs one byte long is silent until something
/// else breaks. And `misalignedAccesses` stays at zero: the host forgives an
/// unaligned access that the kernel, with the MMU off, would take as a fault.
///
/// `.serialized`, and the run needs `--no-parallel`: the misaligned counter is a
/// global.
@Suite("Raw bytes", .serialized)
struct RawBytesTests {

    private static let guardBytes = 64
    private static let guardValue: UInt8 = 0xC3

    /// One page-aligned slab: a guard, `span` bytes to work in, another guard.
    /// Sized per count, so the sweeps stay quick in a debug build.
    private struct Slab {
        let base: UnsafeMutableRawPointer
        let span: Int

        init(span: Int) {
            self.span = span
            base = .allocate(byteCount: span + 2 * guardBytes, alignment: 4096)
        }

        var start: UnsafeMutableRawPointer { base + guardBytes }
        var total: Int { span + 2 * guardBytes }

        subscript(index: Int) -> UInt8 {
            get { base.load(fromByteOffset: index, as: UInt8.self) }
            nonmutating set { base.storeBytes(of: newValue, toByteOffset: index, as: UInt8.self) }
        }

        /// Guards to their value, the working span to a pattern unlike the guards.
        func reset() {
            var index = 0
            while index < total {
                let inside = index >= guardBytes && index < guardBytes + span
                self[index] = inside ? UInt8(truncatingIfNeeded: index &* 7 &+ 1) : guardValue
                index += 1
            }
        }

        func snapshot() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: total)
            var index = 0
            while index < total { bytes[index] = self[index]; index += 1 }
            return bytes
        }

        func matches(_ expected: [UInt8]) -> Bool {
            var index = 0
            while index < total {
                if self[index] != expected[index] { return false }
                index += 1
            }
            return true
        }

        func deallocate() { base.deallocate() }
    }

    private static let shortCounts = Array(0...70) + [127, 128, 129, 255, 256, 257, 4095, 4096, 4097]
    private static let copyCounts  = Array(0...40) + [63, 64, 65, 127, 128, 129, 255, 256, 257, 4096, 4097]
    private static let shiftCounts = Array(1...80) + [300, 4096]


    @Test("fill writes the byte over exactly the range, at every offset")
    func fillWritesExactlyTheRange() {
        RawBytes.misalignedAccesses = 0
        var failure: String?
        for count in Self.shortCounts {
            let slab = Slab(span: 32 + count)
            defer { slab.deallocate() }

            for offset in 0..<32 {
                for byte: UInt8 in [0x00, 0x5A, 0xFF] where failure == nil {
                    slab.reset()
                    var expected = slab.snapshot()
                    var index = 0
                    while index < count { expected[Self.guardBytes + offset + index] = byte; index += 1 }

                    RawBytes.fill(slab.start + offset, with: byte, count: count)
                    if !slab.matches(expected) { failure = "offset \(offset) count \(count) byte \(byte)" }
                }
            }
        }

        #expect(failure == nil, "\(failure ?? "")")
        #expect(RawBytes.misalignedAccesses == 0)
    }

    @Test("copy matches the source at every relative alignment and leaves it alone")
    func copyMatchesSourceAtEveryRelativeAlignment() {
        RawBytes.misalignedAccesses = 0
        var failure: String?
        for count in Self.copyCounts {
            let source      = Slab(span: 16 + count)
            let destination = Slab(span: 16 + count)
            defer { source.deallocate(); destination.deallocate() }

            source.reset()
            let original = source.snapshot()

            for destinationOffset in 0..<16 {
                for sourceOffset in 0..<16 where failure == nil {
                    destination.reset()
                    var expected = destination.snapshot()
                    var index = 0
                    while index < count {
                        expected[Self.guardBytes + destinationOffset + index] =
                            original[Self.guardBytes + sourceOffset + index]
                        index += 1
                    }

                    RawBytes.copy(to: destination.start + destinationOffset,
                                  from: source.start + sourceOffset, count: count)
                    if !destination.matches(expected) || !source.matches(original) {
                        failure = "destination +\(destinationOffset) source +\(sourceOffset) count \(count)"
                    }
                }
            }
        }

        #expect(failure == nil, "\(failure ?? "")")
        #expect(RawBytes.misalignedAccesses == 0)
    }

    @Test("copy is safe when the destination starts before the source")
    func copyIsSafeWhenDestinationPrecedesSource() {
        RawBytes.misalignedAccesses = 0
        let failure = Self.overlapSweep { slab, low, high, count in
            RawBytes.copy(to: slab.start + low, from: slab.start + high, count: count)
            return (destination: low, source: high)
        }

        #expect(failure == nil, "\(failure ?? "")")
        #expect(RawBytes.misalignedAccesses == 0)
    }

    @Test("copyBackward is safe when the destination starts inside the source")
    func copyBackwardIsSafeWhenDestinationFollowsSource() {
        RawBytes.misalignedAccesses = 0
        let failure = Self.overlapSweep { slab, low, high, count in
            RawBytes.copyBackward(to: slab.start + high, from: slab.start + low, count: count)
            return (destination: high, source: low)
        }

        #expect(failure == nil, "\(failure ?? "")")
        #expect(RawBytes.misalignedAccesses == 0)
    }

    @Test("a count of zero or below writes nothing")
    func nonPositiveCountsWriteNothing() {
        RawBytes.misalignedAccesses = 0
        let slab = Slab(span: 64)
        defer { slab.deallocate() }

        for count in [0, -1, Int.min] {
            slab.reset()
            let before = slab.snapshot()

            RawBytes.fill(slab.start, with: 0x5A, count: count)
            RawBytes.copy(to: slab.start, from: slab.start + 32, count: count)
            RawBytes.copyBackward(to: slab.start + 32, from: slab.start, count: count)

            #expect(slab.matches(before), "count \(count)")
        }
        #expect(RawBytes.misalignedAccesses == 0)
    }


    /// Base 0..<16 by shift 1...40 by every count in `shiftCounts`, one slab per
    /// count holding both ranges. `move` copies from one end to the other and says
    /// which way it went; the result is checked against a copy of the original.
    private static func overlapSweep(
        _ move: (Slab, _ low: Int, _ high: Int, _ count: Int) -> (destination: Int, source: Int)
    ) -> String? {
        for count in shiftCounts {
            let slab = Slab(span: 16 + 40 + count)
            defer { slab.deallocate() }

            for base in 0..<16 {
                for shift in 1...40 {
                    slab.reset()
                    let original = slab.snapshot()
                    var expected = original

                    let (destination, source) = move(slab, base, base + shift, count)
                    var index = 0
                    while index < count {
                        expected[guardBytes + destination + index] = original[guardBytes + source + index]
                        index += 1
                    }

                    if !slab.matches(expected) { return "base \(base) shift \(shift) count \(count)" }
                }
            }
        }
        return nil
    }
}
