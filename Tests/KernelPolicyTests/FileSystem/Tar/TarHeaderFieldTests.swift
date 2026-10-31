//
//  TarHeaderFieldTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.


import Testing
@testable import Kernel
import KernelTestSupport

/// The two header rules the walk trusts before it believes a member: a numeric
/// field is octal digits and padding and nothing else, and the block's bytes
/// add up to the checksum it carries.
///
/// Both are pure functions of header bytes, so they are tested on plain arrays,
/// with no staged archive and no kernel globals. What the walk does with a
/// refusal is `TarFileSystemBoundsTests`' business.
extension KernelPolicyTestRoot {
@Suite("Tar header fields")
struct TarHeaderFieldTests {

    // MARK: - Octal fields

    @Test("a well-formed size field parses, whichever way it is padded")
    func octalAcceptsDigitsThenPadding() {
        #expect(octal("00000000013\0") == 11)
        #expect(octal("00000000013 ")  == 11)
        #expect(octal("0000000001 \0") == 1)
        #expect(octal("1\0\0\0\0\0\0\0\0\0\0\0") == 1)
        #expect(octal("1           ") == 1)
        #expect(octal("0\0\0\0\0\0\0\0\0\0\0\0") == 0)
        #expect(octal("00000000000\0") == 0)
    }

    @Test("a field filled with digits and no terminator is still a number")
    func octalAcceptsFullWidth() {
        #expect(octal("000000000013") == 11)
        #expect(octal("777777777777") == 0xF_FFFF_FFFF)
        #expect(octal("77777777777\0") == 0x1_FFFF_FFFF)
    }

    @Test("a field with no digit at all is refused, empty, blank or NUL")
    func octalRefusesNoDigits() {
        #expect(octal("\0\0\0\0\0\0\0\0\0\0\0\0") == nil)
        #expect(octal("            ") == nil)
        #expect(octal(" \0 \0 \0 \0 \0 \0") == nil)
    }

    @Test("a leading space or NUL is refused rather than skipped")
    func octalRefusesLeadingPadding() {
        #expect(octal(" 0000000013\0") == nil)
        #expect(octal("\u{0}0000000013\0") == nil)
    }

    @Test("a digit after the padding is refused, which skipping would have accepted")
    func octalRefusesDigitsAfterPadding() {
        #expect(octal("1\0000000000\0") == nil)
        #expect(octal("1 0000000000\0") == nil)
        #expect(octal("00000000\0013") == nil)
    }

    @Test("a non-octal byte anywhere in the field refuses it, for every byte value")
    func octalRefusesEveryByteInEveryPosition() {
        for position in 0..<12 {
            for byte in 0...255 {
                var field = [UInt8](repeating: 0x30, count: 12)
                field[position] = UInt8(byte)

                // Digits, or padding in the last place and so with nothing after
                // it to contradict it.
                let isDigit   = byte >= 0x30 && byte <= 0x37
                let isPadding = position == 11 && (byte == 0 || byte == 0x20)

                #expect(
                    (octal(field) != nil) == (isDigit || isPadding),
                    Comment(rawValue: "byte 0x\(String(byte, radix: 16)) at \(position)")
                )
            }
        }
    }

    @Test("the digit that skipping used to delete now refuses the whole size")
    func octalDoesNotDeleteTheBadDigit() {
        // `0000000000A7` read as a size: the old reader dropped the `A`, which
        // made it 7. A member that says so is damaged, not seven bytes long.
        #expect(octal("0000000000A7") == nil)
        #expect(octal("00000000108\0") == nil)
        #expect(octal("0000000-0010") == nil)
        #expect(octal("+0000000010\0") == nil)
    }

    @Test("a value that does not fit 64 bits is refused instead of trapping")
    func octalRefusesOverflow() {
        // 22 octal digits hold 66 bits: a 1 followed by twenty-one sevens is
        // exactly 2^64 - 1, and a 2 followed by zeros is one past it.
        let largest = "1" + String(repeating: "7", count: 21)
        #expect(octal(largest, width: 22) == UInt64.max)

        let over = "2" + String(repeating: "0", count: 21)
        #expect(octal(over, width: 22) == nil)

        #expect(octal(String(repeating: "7", count: 24), width: 24) == nil)
    }


    // MARK: - Checksum

    @Test("a header the packer wrote carries a checksum that holds")
    func checksumHoldsForAWellFormedHeader() {
        let header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)

        #expect(checksumHolds(header))
        #expect(UstarLayout.checksumHolds(header, headerAt: 0))
    }

    @Test("flipping any one bit of the block breaks the checksum, bar the pad swap")
    func checksumCatchesEverySingleBitFlip() {
        let header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)

        for index in 0..<512 {
            for bit in 0..<8 {
                var mutant = header
                mutant[index] ^= (1 << UInt8(bit))

                // Bit 5 of the NUL or the space after the digits turns one into
                // the other, and both are padding: the number is the same.
                let isPaddingSwap = (index == 154 || index == 155) && bit == 5

                #expect(
                    checksumHolds(mutant) == isPaddingSwap,
                    Comment(rawValue: "bit \(bit) of byte \(index)")
                )
            }
        }
    }

    @Test("a stored value one off the sum is refused, either way")
    func checksumRefusesAnOffByOneValue() {
        let header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)
        let stored = storedChecksum(header)

        for wrong in [stored &- 1, stored &+ 1, 0, stored ^ 0o100000] {
            var mutant = header
            storeChecksum(wrong, into: &mutant)

            #expect(!checksumHolds(mutant), Comment(rawValue: "stored \(wrong), sum \(stored)"))
        }

        // And the value itself, written back, is what makes it hold.
        var same = header
        storeChecksum(stored, into: &same)
        #expect(checksumHolds(same))
    }

    @Test("the checksum field counts as eight spaces, so what is stored in it never feeds the sum")
    func checksumIgnoresItsOwnField() {
        var header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)

        // Same number, spelled the other common way: digits, space, NUL.
        let stored = storedChecksum(header)
        header.replaceSubrange(148..<156, with: Array(String(stored, radix: 8)
            .leftPadded(to: 6).utf8) + [0x20, 0])
        #expect(checksumHolds(header))

        // Or eight digits and no terminator at all.
        header.replaceSubrange(148..<156, with: Array(String(stored, radix: 8)
            .leftPadded(to: 8).utf8))
        #expect(checksumHolds(header))
    }

    @Test("a checksum field that is not octal is refused however the sum comes out")
    func checksumRefusesAMalformedField() {
        let header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)

        for field in [
            [UInt8](repeating: 0x20, count: 8),
            [UInt8](repeating: 0, count: 8),
            Array(" 006530\0".utf8),
            Array("00653x\0 ".utf8),
            Array("006530\0".utf8) + [0x37],
        ] {
            var mutant = header
            mutant.replaceSubrange(148..<156, with: field)

            #expect(!checksumHolds(mutant), Comment(rawValue: "\(field)"))
        }
    }

    @Test("bytes above 0x7F are summed as unsigned, not sign-extended")
    func checksumIsUnsigned() {
        // 0xE9 is -23 as a signed char. The packer's sum is unsigned, so a name
        // with a high byte only holds under the unsigned rule.
        var header = ustarHeader(name: [0xE9, 0xFF, 0x80, 0x41], size: 11)
        #expect(checksumHolds(header))

        // Re-sealed with the signed sum it must be refused.
        let signed = header.enumerated().reduce(0) { total, item in
            (148..<156).contains(item.offset) ? total + 0x20 : total + Int(Int8(bitPattern: item.element))
        }
        storeChecksum(signed, into: &header)
        #expect(!checksumHolds(header))
    }

    @Test("sealing is idempotent and makes an edited header hold again")
    func sealRestoresTheChecksum() {
        var header = ustarHeader(name: Array("alpha.txt".utf8), size: 11)
        header[100] = 0x31
        #expect(!checksumHolds(header))

        sealUstarHeader(&header, at: 0)
        #expect(checksumHolds(header))

        let once = header
        sealUstarHeader(&header, at: 0)
        #expect(header == once)
    }


    // MARK: - Reading through the kernel's types

    private func octal(_ text: String) -> UInt64? {
        octal(Array(text.utf8), width: text.utf8.count)
    }

    private func octal(_ text: String, width: Int) -> UInt64? {
        octal(Array(text.utf8), width: width)
    }

    private func octal(_ bytes: [UInt8]) -> UInt64? {
        octal(bytes, width: bytes.count)
    }

    private func octal(_ bytes: [UInt8], width: Int) -> UInt64? {
        var padded = bytes
        while padded.count < width { padded.append(0) }

        return padded.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: width) {
                TarInfo.octal($0, width: width)
            }
        }
    }

    private func checksumHolds(_ header: [UInt8]) -> Bool {
        header.withUnsafeBufferPointer { buffer in
            TarInfo(address: PhysicalAddress(UInt(bitPattern: buffer.baseAddress!))).hasValidChecksum
        }
    }

    /// The number stored in the checksum field, for the tests that need to
    /// change it by one.
    private func storedChecksum(_ header: [UInt8]) -> Int {
        header[148..<154].reduce(0) { ($0 << 3) + Int($1 - 0x30) }
    }

    private func storeChecksum(_ value: Int, into header: inout [UInt8]) {
        let digits = String(value & 0o7_777_777, radix: 8).leftPadded(to: 6)
        header.replaceSubrange(148..<156, with: Array(digits.utf8) + [0, 0x20])
    }
}

}


private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}
