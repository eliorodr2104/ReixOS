//
//  TarCorpusFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

/// Field offsets and the two rules a corpus assertion needs: what a member is
/// called, and how big it says it is.
public enum UstarLayout {

    public static let blockSize   = 512
    public static let nameWidth   = 100
    public static let sizeOffset  = 124
    public static let sizeWidth   = 12
    public static let magicOffset = 257

    /// The 100 raw bytes of the name field of the header at `offset`.
    public static func nameField(_ bytes: [UInt8], headerAt offset: Int) -> [UInt8]? {
        guard offset >= 0, offset + blockSize <= bytes.count else { return nil }
        return Array(bytes[offset..<(offset + nameWidth)])
    }

    /// The member name as a string, up to the first NUL.
    public static func name(_ bytes: [UInt8], headerAt offset: Int) -> String? {
        guard let field = nameField(bytes, headerAt: offset) else { return nil }
        return String(decoding: field.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Twelve octal digits, read the way the kernel reads them: every byte
    /// outside `0`..`7` is skipped rather than ending the field.
    ///
    /// Deliberately bug-compatible with `TarFileSystem.getFileSize`, because the
    /// corpus assertions compare against what the kernel will compute, not
    /// against what POSIX would prefer.
    public static func declaredSize(_ bytes: [UInt8], headerAt offset: Int) -> Int? {
        guard offset >= 0, offset + blockSize <= bytes.count else { return nil }

        var result = 0
        for i in 0..<sizeWidth {
            let byte = bytes[offset + sizeOffset + i]
            guard byte >= 0x30, byte <= 0x37 else { continue }
            result = (result << 3) + Int(byte - 0x30)
        }

        return result
    }

    public static func hasUstarMagic(_ bytes: [UInt8], headerAt offset: Int) -> Bool {
        guard offset >= 0, offset + blockSize <= bytes.count else { return false }
        return Array(bytes[(offset + magicOffset)..<(offset + magicOffset + 5)]) == Array("ustar".utf8)
    }

    /// The kernel's exact-match rule, restated: the path has to run out at the
    /// same place the field does, either at a NUL or by filling all 100 bytes.
    ///
    /// This is what makes a prefix (`al` against `alpha.txt`) and an extension
    /// (`alpha.txt` against `alpha.txt.bak`) both misses.
    public static func matches(nameField field: [UInt8], path: String) -> Bool {
        let wanted = Array(path.utf8)
        guard field.count >= nameWidth, wanted.count <= nameWidth, !wanted.contains(0) else {
            return false
        }

        for (i, byte) in wanted.enumerated() where field[i] != byte { return false }

        return wanted.count == nameWidth || field[wanted.count] == 0
    }


    /// One entry of an archive as an independent walk sees it.
    public struct Entry {
        public let headerOffset: Int
        public let dataOffset  : Int
        public let name        : String
        public let size        : Int
    }

    /// Walks `archive` the way the kernel does, stopping at the first header
    /// whose name begins with a NUL, and returns every member it stepped over.
    ///
    /// Returns `nil` when the walk would leave the buffer, which for a corpus
    /// fixture is itself a failure worth reporting.
    public static func members(of archive: [UInt8]) -> [Entry]? {
        var entries: [Entry] = []
        var offset  = 0

        while offset + blockSize <= archive.count {
            if archive[offset] == 0 { return entries }

            guard let name = name(archive, headerAt: offset),
                  let size = declaredSize(archive, headerAt: offset) else { return nil }

            entries.append(Entry(
                headerOffset: offset,
                dataOffset  : offset + blockSize,
                name        : name,
                size        : size
            ))

            offset += blockSize + ((size + 511) & ~511)
        }

        return nil
    }
}


/// An archive whose single member's name fills all 100 bytes of the field with
/// no terminator.
///
/// The one branch of `TarFileSystem.isFileSection`'s exact-match test that the
/// captured corpus cannot reach: `UstarWriter.field` refuses a name that leaves
/// no room for a NUL, so the archive has to be built here, byte by byte, in the
/// same ustar layout the packer emits. See `Tests/Fixtures/tar/README.md`.
public enum FullWidthNameArchive {

    /// Exactly 100 bytes, no NUL. Ends in `.elf` so it reads like a real member.
    public static let name = String(repeating: "n", count: 96) + ".elf"

    public static let contents = Array("full width name payload".utf8)

    public static func archive() -> [UInt8] {
        var bytes = ustarHeader(name: Array(name.utf8), size: contents.count)
        bytes += contents
        bytes += [UInt8](repeating: 0, count: (512 - contents.count % 512) % 512)
        bytes += [UInt8](repeating: 0, count: 1024) // end-of-archive marker
        return bytes
    }
}


/// One 512-byte POSIX ustar header, with a real checksum.
///
/// `TarFileSystem` never verifies the checksum, and the field is filled anyway:
/// a fixture that is only valid because nobody looks is a fixture that stops
/// being valid the day somebody does.
public func ustarHeader(name: [UInt8], size: Int, typeflag: UInt8 = UInt8(ascii: "0")) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: UstarLayout.blockSize)

    for (i, byte) in name.prefix(UstarLayout.nameWidth).enumerated() { header[i] = byte }

    putBytes(ustarOctal(0o644, width: 8),  at: 100, into: &header)
    putBytes(ustarOctal(0, width: 8),      at: 108, into: &header)
    putBytes(ustarOctal(0, width: 8),      at: 116, into: &header)
    putBytes(ustarOctal(size, width: 12),  at: 124, into: &header)
    putBytes(ustarOctal(0, width: 12),     at: 136, into: &header)

    for i in 148..<156 { header[i] = 0x20 } // blanks while the sum is taken
    header[156] = typeflag
    putBytes(Array("ustar".utf8), at: 257, into: &header)
    putBytes(Array("00".utf8),    at: 263, into: &header)

    let sum = header.reduce(0) { $0 + Int($1) }
    var checksum = ustarOctalDigits(sum, count: 6)
    checksum.append(0)
    checksum.append(0x20)
    putBytes(checksum, at: 148, into: &header)

    return header
}


private func ustarOctal(_ value: Int, width: Int) -> [UInt8] {
    ustarOctalDigits(value, count: width - 1) + [0]
}

private func ustarOctalDigits(_ value: Int, count: Int) -> [UInt8] {
    let digits = String(value, radix: 8)
    precondition(digits.count <= count, "ustar: \(value) does not fit \(count) octal digits")
    return Array((String(repeating: "0", count: count - digits.count) + digits).utf8)
}

private func putBytes(_ value: [UInt8], at offset: Int, into bytes: inout [UInt8]) {
    for (i, byte) in value.enumerated() { bytes[offset + i] = byte }
}
