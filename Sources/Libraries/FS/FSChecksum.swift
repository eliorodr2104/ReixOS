//
//  FSChecksum.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// The one checksum this format uses: CRC32C, Castagnoli's polynomial as iSCSI,
/// ext4 and btrfs use it, with one field read as zero so a block can carry its
/// own checksum.
///
/// It replaced FNV-1a, whose every byte waited on a multiply of the byte before.
/// Under `-mstrict-align` that was forty-three instructions per eight bytes, and
/// two thirds of everything the file system server ran from boot to the shell;
/// `crc32cx` takes the eight bytes in one. What it has to catch is what it was:
/// a block half written, a block from another moment, a block of zeroes. A CRC
/// also catches every burst of up to thirty-two bits, which FNV-1a never promised.
///
/// A program runs the generated `reix_crc32c`; a host build, which formats disk
/// images and runs the tests, runs the same function as tables in Swift. CRC32
/// is part of the platform and not probed: Cortex-A53 has it, and a core without
/// it kills the server on an illegal instruction at its first checksum, which
/// a mount takes before it writes anything.
enum FSChecksum {

    /// The checksum of no bytes, which is where one over several pieces starts.
    static let empty: UInt32 = 0

    /// Over `count` bytes of `base`, reading the `width` bytes at `zeroing` as
    /// zero; a window past the end reads nothing beyond it.
    ///
    /// `zeroing` is negative to checksum the whole range. `continuing` is the
    /// checksum of whatever came before, so a structure that spans several
    /// blocks is one checksum and not one per block.
    static func over(
        _ base    : UnsafeRawPointer,
        count     : Int,
        zeroing   : Int = -1,
        width     : Int = 4,
        continuing: UInt32 = empty
    ) -> UInt32 {

        guard zeroing >= 0 else { return update(continuing, base, count) }

        let head = min(zeroing, count)
        let hole = max(0, min(width, count - head))
        let zero = UInt64(0)

        var sum  = update(continuing, base, head)
        var left = hole

        while left > 0 {
            let step = min(left, 8)
            sum   = withUnsafeBytes(of: zero) { update(sum, $0.baseAddress!, step) }
            left -= step
        }

        return update(sum, base + head + hole, count - head - hole)
    }


    /// Folds `count` bytes at `base` into `sum`; nothing for a count of zero or less.
    private static func update(_ sum: UInt32, _ base: UnsafeRawPointer, _ count: Int) -> UInt32 {
        guard count > 0 else { return sum }
        #if hasFeature(Embedded)
        return reixCRC32C(sum, base, count)
        #else
        return software(sum, base, count)
        #endif
    }


    #if !hasFeature(Embedded)
    /// Castagnoli's polynomial, bit reversed for a CRC that takes the low bit first.
    private static let polynomial: UInt32 = 0x82F6_3B78

    /// Eight tables of 256: the first is one byte's step, and each next one the
    /// same byte one place further back, so eight bytes cost eight lookups.
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for byte in 0..<256 {
            var crc = UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ polynomial
            }
            tables[byte] = crc
        }
        for slice in 1..<8 {
            for byte in 0..<256 {
                let prev = tables[(slice - 1) * 256 + byte]
                tables[slice * 256 + byte] = (prev >> 8) ^ tables[Int(prev & 0xFF)]
            }
        }
        return tables
    }()

    /// Slicing by eight, which agrees with `crc32cx` bit for bit.
    private static func software(_ sum: UInt32, _ base: UnsafeRawPointer, _ count: Int) -> UInt32 {
        tables.withUnsafeBufferPointer { t in
            var crc   = ~sum
            let words = count / 8
            for index in 0..<words {
                let word = UInt64(littleEndian: base.loadUnaligned(
                    fromByteOffset: index * 8, as: UInt64.self
                ))
                let low  = crc ^ UInt32(truncatingIfNeeded: word)
                let high = UInt32(truncatingIfNeeded: word >> 32)
                let front = t[7 * 256 + Int(low & 0xFF)]
                    ^ t[6 * 256 + Int((low >> 8) & 0xFF)]
                    ^ t[5 * 256 + Int((low >> 16) & 0xFF)]
                    ^ t[4 * 256 + Int(low >> 24)]
                let back = t[3 * 256 + Int(high & 0xFF)]
                    ^ t[2 * 256 + Int((high >> 8) & 0xFF)]
                    ^ t[256 + Int((high >> 16) & 0xFF)]
                    ^ t[Int(high >> 24)]
                crc = front ^ back
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for index in (words * 8)..<count {
                crc = t[Int((crc ^ UInt32(bytes[index])) & 0xFF)] ^ (crc >> 8)
            }
            return ~crc
        }
    }
    #endif


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

#if hasFeature(Embedded)
/// The `crc32c` instructions, which Swift has no spelling for, generated by the
/// reix AsmDSL into every program. Takes and returns a finished checksum.
@_silgen_name("reix_crc32c")
private func reixCRC32C(_ sum: UInt32, _ base: UnsafeRawPointer, _ count: Int) -> UInt32
#endif
