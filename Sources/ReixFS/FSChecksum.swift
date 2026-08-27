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

    private static let offsetBasis: UInt32 = 0x811C_9DC5
    private static let prime      : UInt32 = 0x0100_0193

    /// Over `count` bytes of `base`, reading the four bytes at `zeroing` as zero.
    ///
    /// `zeroing` is negative to checksum the whole range.
    static func over(
        _ base : UnsafeRawPointer,
        count  : Int,
        zeroing: Int = -1
    ) -> UInt32 {

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash  = offsetBasis

        for index in 0..<count {
            let byte = (zeroing >= 0 && index >= zeroing && index < zeroing + 4)
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
