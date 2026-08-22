//
//  SeededMutation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.


/// SplitMix64, the generator Swift's own `SystemRandomNumberGenerator`
/// documentation points at for reproducible streams.
///
/// Written out rather than pulled from a package because the whole value of a
/// seeded corpus is that the stream is pinned: this is twelve lines whose
/// output is fixed by the constants, so a failure quoted as
/// "seed 0x9E3779B97F4A7C15, case 41" can be reproduced anywhere.
public struct SplitMix64 {

    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A draw in `0..<bound`.
    ///
    /// Plain modulo. The bias is at most one part in 2^64 / bound and cannot
    /// matter to a corpus whose bounds are all under a few million, and the
    /// alternative, rejection sampling, would make the stream depend on how
    /// many draws were rejected.
    public mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0, "SplitMix64.below needs a positive bound")
        return Int(next() % UInt64(bound))
    }

    /// One element of `choices`, which must not be empty.
    public mutating func pick<T>(_ choices: [T]) -> T {
        choices[below(choices.count)]
    }
}


/// One edit to one blob. A case's whole diff is an array of these, which is
/// what a failure message can print instead of a 1 MiB hexdump.
public enum ByteMutation: CustomStringConvertible {

    /// Flips a single bit, the mutation that keeps a blob closest to valid.
    case flipBit(offset: Int, bit: UInt8)

    /// Overwrites a byte, drawn from a set of values that mean something to a
    /// parser: a terminator, an all-ones, a plausible small count.
    case setByte(offset: Int, value: UInt8)

    /// Zeroes everything from `from` to the end of the live extent.
    ///
    /// A truncation as the kernel can actually see one: the bytes are gone but
    /// the memory they sat in is not, and it reads back as zero. Shortening the
    /// buffer instead would model a blob whose declared size outruns its
    /// mapping, which no bootloader hands over and which the parser is not
    /// asked to survive.
    case zeroTail(from: Int, upTo: Int)

    /// Replaces a big-endian 32-bit field, for the header words whose whole
    /// job is to say how long something is.
    case setWord(offset: Int, value: UInt32)

    public var description: String {
        switch self {
            case .flipBit(let offset, let bit):
                "flipBit(0x\(String(offset, radix: 16)), bit \(bit))"

            case .setByte(let offset, let value):
                "setByte(0x\(String(offset, radix: 16)), 0x\(String(value, radix: 16)))"

            case .zeroTail(let from, let upTo):
                "zeroTail(0x\(String(from, radix: 16))..<0x\(String(upTo, radix: 16)))"

            case .setWord(let offset, let value):
                "setWord(0x\(String(offset, radix: 16)), 0x\(String(value, radix: 16)))"
        }
    }

    public func apply(to bytes: inout [UInt8]) {
        switch self {
            case .flipBit(let offset, let bit):
                guard bytes.indices.contains(offset) else { return }
                bytes[offset] ^= (1 << (bit & 7))

            case .setByte(let offset, let value):
                guard bytes.indices.contains(offset) else { return }
                bytes[offset] = value

            case .zeroTail(let from, let upTo):
                let end = min(upTo, bytes.count)
                guard from < end else { return }
                for i in from..<end { bytes[i] = 0 }

            case .setWord(let offset, let value):
                guard offset >= 0, offset + 4 <= bytes.count else { return }
                bytes[offset + 0] = UInt8(truncatingIfNeeded: value >> 24)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
        }
    }
}


/// A mutant: the bytes handed to the parser plus the edits that made them.
public struct Mutant {
    public let index: Int
    public let bytes: [UInt8]
    public let edits: [ByteMutation]

    public init(index: Int, bytes: [UInt8], edits: [ByteMutation]) {
        self.index = index
        self.bytes = bytes
        self.edits = edits
    }

    /// What a failed expectation prints. The seed is in the test name, so the
    /// case index and this list are enough to rebuild the exact blob.
    public var label: String {
        "case \(index): " + edits.map(\.description).joined(separator: ", ")
    }
}


/// `count` mutants of `blob`, drawn from one seed.
///
/// The plan is built in full before anything is parsed, which is what makes a
/// seed reproducible independently of how the suite consumes it: a run that
/// bailed out early would otherwise leave the generator in a different state
/// than a run that did not.
public func makeMutants(
    of blob : [UInt8],
    seed    : UInt64,
    count   : Int,
    drawing edits: (inout MutationPlanner, Int) -> [ByteMutation]
) -> [Mutant] {

    var planner = MutationPlanner(seed: seed)

    return (0..<count).map { index in
        let plan = edits(&planner, planner.editCount())

        var bytes = blob
        for edit in plan { edit.apply(to: &bytes) }

        return Mutant(index: index, bytes: bytes, edits: plan)
    }
}


/// Draws mutation plans from one seed.
///
/// A plan is a *family* plus a handful of edits from it, never a mix. Families
/// are separated on purpose: a header field that grows the struct block plus a
/// flip that removes `FDT_END` in the same case turns a bounded walk into a
/// multi-million-iteration one, and the case that finds a real bug stops being
/// the case that is cheap to explain.
public struct MutationPlanner {

    /// Byte values worth writing over a parser's input.
    ///
    /// `0x00` ends a string and marks end-of-archive, `0xFF` is the all-ones a
    /// length field reads as enormous, `0x2F` and `0x30`..`0x38` bracket the
    /// octal digits ustar sizes are made of, and `0x80` sets the high bit of
    /// whatever cell it lands in.
    public static let adversarialBytes: [UInt8] = [
        0x00, 0x01, 0x2F, 0x30, 0x37, 0x38, 0x41, 0x7F, 0x80, 0xFE, 0xFF,
    ]

    private var rng: SplitMix64

    public init(seed: UInt64) {
        self.rng = SplitMix64(seed: seed)
    }

    /// Edits inside `range`, drawn from the bit-flip, byte-overwrite and
    /// truncation families. `range` is the live extent of the blob, never its
    /// declared padding: a flip in a region no parser reads is a case that
    /// cannot fail, and spending the budget on those is how a fuzzer ends up
    /// green for the wrong reason.
    public mutating func structuralEdits(in range: Range<Int>, count: Int) -> [ByteMutation] {
        var edits: [ByteMutation] = []

        for _ in 0..<count {
            let offset = range.lowerBound + rng.below(range.count)

            switch rng.below(8) {
                case 0:
                    edits.append(.zeroTail(from: offset, upTo: range.upperBound))

                case 1, 2, 3:
                    edits.append(.setByte(offset: offset, value: rng.pick(Self.adversarialBytes)))

                default:
                    edits.append(.flipBit(offset: offset, bit: UInt8(rng.below(8))))
            }
        }

        return edits
    }

    /// Edits that replace whole big-endian length or offset fields, one per
    /// call, at one of `fields`.
    ///
    /// `current` is read so the plan can also produce the off-by-one neighbours
    /// of the real value, which are the ones a bounds check gets wrong.
    public mutating func lengthFieldEdits(
        at fields  : [Int],
        current    : (Int) -> UInt32,
        count      : Int
    ) -> [ByteMutation] {

        var edits: [ByteMutation] = []

        for _ in 0..<count {
            let field = rng.pick(fields)
            let real  = current(field)

            let absolute: [UInt32] = [
                0, 1, 4, 0x27, 0x28, 0x2C, 0x100, 0x1000, 0x10000,
                0x100000, 0x100004, 0x200000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
            ]
            let neighbours: [UInt32] = [
                real &- 4, real &- 1, real &+ 1, real &+ 4, real &+ 512,
                real >> 1, real << 1, real ^ 0x80000000,
            ]

            let value = rng.below(2) == 0 ? rng.pick(absolute) : rng.pick(neighbours)
            edits.append(.setWord(offset: field, value: value))
        }

        return edits
    }

    /// How many edits this case gets: one most of the time, up to four
    /// sometimes, so a guard that only breaks under two simultaneous edits is
    /// still reachable without making every case hard to read.
    public mutating func editCount() -> Int {
        1 + rng.below(4)
    }

    /// A draw the caller can use to choose between its own families.
    public mutating func choice(_ bound: Int) -> Int {
        rng.below(bound)
    }
}
