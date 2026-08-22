//
//  UstarWriter.swift
//  ReixOS
//
//  Created by Eliomar on 04/08/2026.


import Foundation

/// A minimal ustar archive writer that page-aligns every member's data.
///
/// The kernel's `TarFileSystem` maps ELF segments straight out of the initrd
/// image, which only works when a member's data starts on a page boundary.
/// `/usr/bin/tar` has no knob for that, so this replaces it: it writes plain
/// POSIX ustar headers and inserts an `@pad` filler member before any header
/// that would otherwise land data off a 4096 boundary.
///
/// `@pad` is itself a well-formed member (typeflag '0', real name, real size)
/// rather than raw zero bytes: `TarFileSystem.findFile` treats a zero name
/// byte as end-of-archive, so padding has to walk like any other entry.
enum UstarWriter {

    struct Member {
        let name: String
        let data: Data
    }

    /// Bytes of a ustar archive holding `members` in order, followed by the
    /// two zero blocks that mark end-of-archive.
    static func write(members: [Member]) -> Data {
        var archive = Data()

        for member in members {
            padIfNeeded(&archive)

            precondition(archive.count % 4096 == 3584,
                         "ustar: \(member.name) header is not positioned for aligned data")
            archive.append(header(name: member.name, size: member.data.count, typeflag: "0"))

            precondition(archive.count % 4096 == 0,
                         "ustar: \(member.name) data is not 4096-aligned")
            archive.append(member.data)
            appendBlockPadding(&archive, dataSize: member.data.count)
        }

        archive.append(Data(count: 1024)) // two zero blocks: end-of-archive marker
        return archive
    }

    /// Re-walks a finished archive the same way `TarFileSystem.findFile` does
    /// and checks every real member's data offset. Independent of `write`'s
    /// own bookkeeping, so it actually catches a broken writer instead of
    /// just echoing its assumptions back. `@pad` fillers are exempt: their
    /// job is to shift the *next* header, not to be aligned themselves.
    static func verifyPageAlignment(_ archive: Data) -> Bool {
        let base = archive.startIndex
        var offset = 0

        while offset + 512 <= archive.count {
            let nameStart = base + offset
            if archive[nameStart] == 0 { break } // end-of-archive marker

            let nameField = archive[nameStart..<(nameStart + 100)]
            let name = String(decoding: nameField.prefix(while: { $0 != 0 }), as: UTF8.self)

            let sizeField = archive[(base + offset + 124)..<(base + offset + 136)]
            let size = parseOctal(sizeField)
            let dataOffset = offset + 512

            if name != "@pad", dataOffset % 4096 != 0 { return false }

            offset = dataOffset + ((size + 511) & ~511)
        }

        return true
    }


    // MARK: - Padding

    /// Inserts an `@pad` member before the next header when needed, so that
    /// header lands at an archive offset ≡ 3584 (mod 4096) and its data,
    /// 512 bytes later, lands on a page boundary.
    private static func padIfNeeded(_ archive: inout Data) {
        // The math below assumes archive.count is already a 512 multiple,
        // true only because every caller appends header+data in 512 units.
        precondition(archive.count % 512 == 0, "ustar: archive is not 512-aligned")

        let mod = archive.count % 4096
        guard mod != 3584 else { return } // next header already lands right

        let padDataSize = ((3072 - mod) % 4096 + 4096) % 4096
        archive.append(header(name: "@pad", size: padDataSize, typeflag: "0"))
        archive.append(Data(count: padDataSize))
    }

    /// ustar pads every member's data to a 512-byte multiple.
    private static func appendBlockPadding(_ archive: inout Data, dataSize: Int) {
        let remainder = dataSize % 512
        if remainder != 0 { archive.append(Data(count: 512 - remainder)) }
    }


    // MARK: - Header

    /// One 512-byte POSIX ustar header. mtime is always 0: the archive must
    /// build byte-identical across runs.
    private static func header(name: String, size: Int, typeflag: Unicode.Scalar) -> Data {
        var bytes = [UInt8](repeating: 0, count: 512)

        set(&bytes, field(name, width: 100), at: 0)
        set(&bytes, octalField(0o644, width: 8), at: 100)  // mode
        set(&bytes, octalField(0, width: 8), at: 108)      // uid
        set(&bytes, octalField(0, width: 8), at: 116)      // gid
        set(&bytes, octalField(size, width: 12), at: 124)  // size
        set(&bytes, octalField(0, width: 12), at: 136)     // mtime = 0
        for i in 148..<156 { bytes[i] = 0x20 }              // chksum: spaces while summing
        bytes[156] = UInt8(typeflag.value)                  // typeflag
        set(&bytes, field("ustar", width: 6), at: 257)      // magic "ustar\0"
        set(&bytes, Array("00".utf8), at: 263)              // version "00", no NUL

        let sum = bytes.reduce(0) { $0 + Int($1) }
        set(&bytes, chksumField(sum), at: 148)

        return Data(bytes)
    }

    /// six octal digits, a NUL, then a space: the one ustar field with its
    /// own oddball layout, distinct from every other numeric field.
    private static func chksumField(_ value: Int) -> [UInt8] {
        var out = octalDigits(value, count: 6)
        out.append(0)
        out.append(0x20)
        return out
    }

    /// A numeric field: `width - 1` zero-padded octal digits, NUL-terminated.
    private static func octalField(_ value: Int, width: Int) -> [UInt8] {
        var out = octalDigits(value, count: width - 1)
        out.append(0)
        return out
    }

    private static func octalDigits(_ value: Int, count: Int) -> [UInt8] {
        let digits = String(value, radix: 8)
        precondition(digits.count <= count, "ustar: \(value) does not fit \(count) octal digits")
        let padded = String(repeating: "0", count: count - digits.count) + digits
        return Array(padded.utf8)
    }

    /// A text field: UTF-8 bytes, zero-padded (and NUL-terminated, when it
    /// fits) to `width`.
    private static func field(_ string: String, width: Int) -> [UInt8] {
        let raw = Array(string.utf8)
        precondition(raw.count < width, "ustar: \"\(string)\" does not fit a \(width)-byte field")
        return raw + [UInt8](repeating: 0, count: width - raw.count)
    }

    private static func set(_ bytes: inout [UInt8], _ value: [UInt8], at offset: Int) {
        for (i, b) in value.enumerated() { bytes[offset + i] = b }
    }

    private static func parseOctal(_ field: Data) -> Int {
        var result = 0
        for byte in field where byte >= 0x30 && byte <= 0x37 {
            result = (result << 3) + Int(byte - 0x30)
        }
        return result
    }
}
