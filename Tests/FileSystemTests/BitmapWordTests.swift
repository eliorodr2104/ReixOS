//
//  BitmapWordTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.

import Testing
import ReixABI
@testable import ReixFS

/// A word at a time has to mean the same thing as a bit at a time.
///
/// The map is one block of four thousand and ninety-six bytes, so thirty-two
/// thousand seven hundred and sixty-eight blocks: five hundred and twelve words,
/// with every awkward case inside it - ranges that start mid-word, ranges that
/// end mid-word, ranges as wide as a word, a block whose last word is short.
@Suite("The block map, a word at a time")
struct BitmapWordTests {

    private static let bytes = Int(FSLayout.blockSize)
    private static let bits  = Int(FSLayout.blockSize) * 8


    /// A deterministic pattern generator, so a failure is one somebody can run
    /// again. Not `Math.random`: a property test nobody can reproduce is a
    /// property test that reports a shape it cannot show you.
    private struct Dice {
        private var state: UInt64

        init(_ seed: UInt64) { self.state = seed | 1 }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func below(_ bound: Int) -> Int {
            bound <= 0 ? 0 : Int(next() % UInt64(bound))
        }
    }


    private func withMaps(
        _ body: (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Void
    ) {
        let word = UnsafeMutableRawPointer.allocate(byteCount: Self.bytes, alignment: 8)
        let slow = UnsafeMutableRawPointer.allocate(byteCount: Self.bytes, alignment: 8)
        defer { word.deallocate(); slow.deallocate() }

        body(word, slow)
    }


    /// Paints both copies with the same pattern.
    private func paint(
        _ word: UnsafeMutableRawPointer,
        _ slow: UnsafeMutableRawPointer,
        _ used: (Int) -> Bool
    ) {
        for byte in 0..<Self.bytes {
            var value = UInt8(0)
            for bit in 0..<8 where used(byte * 8 + bit) { value |= (1 << UInt8(bit)) }

            word.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
            slow.storeBytes(of: value, toByteOffset: byte, as: UInt8.self)
        }
    }

    private func same(
        _ word: UnsafeRawPointer,
        _ slow: UnsafeRawPointer,
        _ what: String
    ) -> Bool {
        for byte in 0..<Self.bytes {
            let one = word.loadUnaligned(fromByteOffset: byte, as: UInt8.self)
            let two = slow.loadUnaligned(fromByteOffset: byte, as: UInt8.self)

            guard one == two else {
                Issue.record("\(what): byte \(byte) is \(one), the reference says \(two)")
                return false
            }
        }
        return true
    }


    /// The shapes worth trying, by name.
    private static let shapes: [(String, (Int) -> Bool)] = [
        ("empty",                 { _ in false }),
        ("full",                  { _ in true }),
        ("every other",           { $0 % 2 == 1 }),
        ("eights",                { ($0 / 8) % 2 == 1 }),
        ("words",                 { ($0 / 64) % 2 == 1 }),
        ("one taken at 63",       { $0 == 63 }),
        ("one taken at 64",       { $0 == 64 }),
        ("one free at 63",        { $0 != 63 }),
        ("all but the last word", { $0 < BitmapWordTests.bits - 64 }),
    ]


    // MARK: - Setting and clearing

    @Test("setting and clearing any range writes the same bytes as a bit at a time")
    func setMatchesTheReference() {
        withMaps { word, slow in
            var dice = Dice(0x5EED_1234)

            for (name, used) in Self.shapes {
                for _ in 0..<200 {
                    paint(word, slow, used)

                    let first = dice.below(Self.bits)
                    let count = 1 + dice.below(min(200, Self.bits - first))
                    let take  = dice.next() & 1 == 0

                    FSBitmap.set(word, from: first, count: count, used: take)
                    SlowBitmap.set(slow, from: first, count: count, used: take)

                    guard same(word, slow, "\(name) set \(first)+\(count) \(take)") else {
                        return
                    }
                }
            }
        }
    }


    @Test("the awkward widths, named rather than left to chance")
    func setAtTheEdges() {
        withMaps { word, slow in
            let cases: [(Int, Int)] = [
                (0, 1), (0, 63), (0, 64), (0, 65), (0, Self.bits),
                (1, 63), (1, 64), (63, 1), (63, 2), (63, 64), (63, 65),
                (64, 1), (64, 64), (Self.bits - 1, 1), (Self.bits - 64, 64),
                (Self.bits - 65, 65),
            ]

            for (first, count) in cases {
                for take in [true, false] {
                    for (name, used) in Self.shapes {
                        paint(word, slow, used)

                        FSBitmap.set(word, from: first, count: count, used: take)
                        SlowBitmap.set(slow, from: first, count: count, used: take)

                        guard same(word, slow, "\(name) \(first)+\(count) \(take)") else {
                            return
                        }
                    }
                }
            }
        }
    }


    // MARK: - Asking

    @Test("every question about a range has the same answer either way")
    func questionsMatchTheReference() {
        withMaps { word, slow in
            var dice = Dice(0xABCD_0F0F)

            for (name, used) in Self.shapes {
                paint(word, slow, used)

                for _ in 0..<400 {
                    let first = dice.below(Self.bits)
                    let count = 1 + dice.below(min(300, Self.bits - first))

                    let clear = FSBitmap.allClear(word, from: first, count: count)
                    #expect(
                        clear == SlowBitmap.allClear(slow, from: first, count: count),
                        "\(name) allClear \(first)+\(count)"
                    )

                    let counted = FSBitmap.clearCount(word, from: first, count: count)
                    #expect(
                        counted == SlowBitmap.clearCount(slow, from: first, count: count),
                        "\(name) clearCount \(first)+\(count)"
                    )
                }
            }
        }
    }


    @Test("the run at each end of the block is the same length either way")
    func edgesMatchTheReference() {
        withMaps { word, slow in
            var dice = Dice(0x1111_2222)

            for (name, used) in Self.shapes {
                paint(word, slow, used)

                // Every width worth trying, including ones that stop mid-word:
                // the last word of a short disk is exactly that case.
                for bits in [1, 63, 64, 65, 127, 128, 1000, Self.bits - 1, Self.bits] {
                    #expect(
                        FSBitmap.leadingClear(word, bits: bits)
                            == SlowBitmap.leadingClear(slow, bits: bits),
                        "\(name) leading \(bits)"
                    )
                    #expect(
                        FSBitmap.trailingClear(word, bits: bits)
                            == SlowBitmap.trailingClear(slow, bits: bits),
                        "\(name) trailing \(bits)"
                    )
                }

                for _ in 0..<50 {
                    let bits = 1 + dice.below(Self.bits)

                    #expect(
                        FSBitmap.leadingClear(word, bits: bits)
                            == SlowBitmap.leadingClear(slow, bits: bits),
                        "\(name) leading \(bits)"
                    )
                    #expect(
                        FSBitmap.trailingClear(word, bits: bits)
                            == SlowBitmap.trailingClear(slow, bits: bits),
                        "\(name) trailing \(bits)"
                    )
                }
            }
        }
    }


    // MARK: - The search

    @Test("the fold finds the block a bit-at-a-time first fit would")
    func runMatchesTheReference() {
        withMaps { word, slow in
            var dice = Dice(0x7777_3333)

            for (name, used) in Self.shapes {
                paint(word, slow, used)

                for count in [1, 2, 3, 7, 8, 9, 63, 64, 65, 200] {
                    for first in [0, 1, 63, 64, 65, 1000, Self.bits - 1] {
                        for bits in [Self.bits, Self.bits - 1, Self.bits - 64, 1000, 64, 1] {

                            let fold = FSBitmap.firstRun(
                                word, ofAtLeast: count, from: first, bits: bits
                            )
                            let slow_ = SlowBitmap.firstRun(
                                slow, ofAtLeast: count, from: first, bits: bits
                            )

                            guard fold == slow_ else {
                                let one = String(describing: fold)
                                let two = String(describing: slow_)

                                Issue.record(
                                    "\(name) run of \(count) from \(first) in \(bits): \(one) against \(two)"
                                )
                                return
                            }
                        }
                    }
                }

                for _ in 0..<400 {
                    let count = 1 + dice.below(300)
                    let first = dice.below(Self.bits)
                    let bits  = 1 + dice.below(Self.bits)

                    let fold = FSBitmap.firstRun(
                        word, ofAtLeast: count, from: first, bits: bits
                    )
                    let slow_ = SlowBitmap.firstRun(
                        slow, ofAtLeast: count, from: first, bits: bits
                    )

                    guard fold == slow_ else {
                        let one = String(describing: fold)
                        let two = String(describing: slow_)

                        Issue.record(
                            "\(name) run of \(count) from \(first) in \(bits): \(one) against \(two)"
                        )
                        return
                    }
                }
            }
        }
    }


    @Test("a run the fold hands back really is that many free blocks")
    func whatTheFoldFindsIsFree() {
        withMaps { word, slow in
            var dice = Dice(0xFEED_BEEF)

            for (_, used) in Self.shapes {
                paint(word, slow, used)

                for _ in 0..<300 {
                    let count = 1 + dice.below(200)
                    let first = dice.below(Self.bits)

                    guard let at = FSBitmap.firstRun(
                        word, ofAtLeast: count, from: first, bits: Self.bits
                    ) else { continue }

                    // Inside the window it was asked about, and every block of it
                    // free. The first half is what stops a run running off the
                    // end of the disk; the second is what stops one being handed
                    // to two files.
                    #expect(at >= first)
                    #expect(at + count <= Self.bits)
                    #expect(SlowBitmap.allClear(slow, from: at, count: count))
                }
            }
        }
    }
}
