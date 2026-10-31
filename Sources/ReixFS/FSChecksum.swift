//
//  FSChecksum.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// The one checksum this format uses.
///
/// FNV-1a over bytes, with one field read as zero so a block can carry its own
/// checksum. Not a cryptographic hash and not meant to be: what it has to catch
/// is a block half written, a block from another moment, and a block of zeroes,
/// and thirty-two bits of avalanche over a hundred bytes catches all three.
enum FSChecksum {

    static let offsetBasis: UInt32 = 0x811C_9DC5
    private static let prime      : UInt32 = 0x0100_0193

    /// Over `count` bytes of `base`, reading the `width` bytes at `zeroing` as
    /// zero.
    ///
    /// `zeroing` is negative to checksum the whole range. `continuing` is the
    /// checksum of whatever came before, so a structure that spans several
    /// blocks is one checksum and not one per block.
    static func over(
        _ base    : UnsafeRawPointer,
        count     : Int,
        zeroing   : Int = -1,
        width     : Int = 4,
        continuing: UInt32 = offsetBasis
    ) -> UInt32 {

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash  = continuing

        // The common case, without the per-byte question and eight bytes to a
        // load: every metadata block a mount reads goes through here.
        guard zeroing >= 0 else {
            let words = count / 8

            for index in 0..<words {
                let word = UInt64(littleEndian: base.loadUnaligned(
                    fromByteOffset: index * 8, as: UInt64.self
                ))

                hash = (hash ^ UInt32(truncatingIfNeeded: word        & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >>  8 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 16 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 24 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 32 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 40 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 48 & 0xFF)) &* prime
                hash = (hash ^ UInt32(truncatingIfNeeded: word >> 56)) &* prime
            }

            for index in (words * 8)..<count { hash = (hash ^ UInt32(bytes[index])) &* prime }
            return hash
        }

        for index in 0..<count {
            let byte = (index >= zeroing && index < zeroing + width)
                ? UInt8(0)
                : bytes[index]

            hash = (hash ^ UInt32(byte)) &* prime
        }

        return hash
    }


    /// Whether every byte of `count` bytes at `base` is zero.
    ///
    /// Eight at a time, which is five hundred and twelve comparisons over a block
    /// on the one path where being sure is worth more than being quick: the
    /// answer decides whether a disk may be written over.
    static func isZero(_ base: UnsafeRawPointer, count: Int) -> Bool {

        let words = count / 8

        for index in 0..<words
        where base.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) != 0 {
            return false
        }

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for index in (words * 8)..<count where bytes[index] != 0 { return false }

        return true
    }
}
