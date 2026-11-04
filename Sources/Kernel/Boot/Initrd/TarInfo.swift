//
//  TarInfo.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

@frozen
public struct TarInfo {
    let address: PhysicalAddress
    
    
    var name: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address))
    }
    
    var mode: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 100))
    }
    
    var uid: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 108))
    }
    
    var gid: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 116))
    }
    
    var size: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 124))
    }
    
    var mtime: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 136))
    }
    
    var chksum: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 148))
    }
    
    var typeflag: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 156))
    }
    
    var linkname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 157))
    }
    
    var magic: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 257))
    }
    
    var version: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 263))
    }
    
    var uname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 265))
    }
    
    var gname: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 297))
    }
    
    var devmajor: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 329))
    }
    
    var devminor: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 337))
    }
    
    var prefix: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 345))
    }
    
    var pad: UnsafePointer<CChar>? {
        UnsafePointer(bitPattern: UInt(address + 500))
    }
}


// MARK: - Header validation

extension TarInfo {

    static let blockSize        = 512
    static let sizeFieldWidth   = 12
    static let chksumFieldWidth = 8

    /// A numeric header field, or `nil` when it is not one.
    ///
    /// Octal digits, at least one, then only NUL or space padding to the end of
    /// the field. Anything else (a sign, a letter, a digit after the padding)
    /// refuses the whole field: skipping a bad byte would turn a corrupt size
    /// into a different, plausible one, and a size is what the walk steps by.
    static func octal(_ field: UnsafePointer<CChar>, width: Int) -> UInt64? {
        var value : UInt64 = 0
        var index = 0

        while index < width {
            let byte = UInt8(bitPattern: field[index])
            guard byte >= 0x30, byte <= 0x37 else { break }

            let (shifted, overflow) = value.multipliedReportingOverflow(by: 8)
            guard !overflow else { return nil }

            value = shifted | UInt64(byte - 0x30)
            index += 1
        }

        guard index > 0 else { return nil }

        while index < width {
            let byte = field[index]
            guard byte == 0 || byte == 0x20 else { return nil }
            index += 1
        }

        return value
    }

    /// Length of the member's data, `nil` when the size field is malformed.
    var contentSize: UInt64? {
        size.flatMap { Self.octal($0, width: Self.sizeFieldWidth) }
    }

    /// True when the stored checksum equals the sum of the block's 512 bytes,
    /// taken with the checksum field itself counted as eight spaces.
    ///
    /// The one integrity check a ustar header carries, and the only thing that
    /// tells a flipped bit in a size or name from a real member before the walk
    /// trusts it.
    var hasValidChecksum: Bool {
        guard let bytes  = UnsafePointer<UInt8>(bitPattern: UInt(address)),
              let field  = chksum,
              let stored = Self.octal(field, width: Self.chksumFieldWidth)
        else { return false }

        let first = 148
        let last  = first + Self.chksumFieldWidth

        var sum: UInt64 = 0
        for index in 0..<Self.blockSize {
            sum += (index >= first && index < last) ? 0x20 : UInt64(bytes[index])
        }

        return sum == stored
    }
}
