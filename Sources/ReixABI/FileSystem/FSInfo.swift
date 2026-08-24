//
//  FSInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// What an object is, as it travels through a client's window.
///
/// A record and not four more words in a message, because there are more than
/// four things worth knowing and because the next thing worth knowing should
/// not cost another operation. It is written and read at a fixed offset with no
/// padding assumptions: both sides store field by field.
public struct FSInfo {

    public var kind    : FSKind
    public var size    : UInt64
    public var blocks  : UInt32
    public var created : Time
    public var modified: Time

    /// Bytes on the wire.
    public static let width = 32

    public init(
        kind    : FSKind,
        size    : UInt64,
        blocks  : UInt32,
        created : Time,
        modified: Time
    ) {
        self.kind     = kind
        self.size     = size
        self.blocks   = blocks
        self.created  = created
        self.modified = modified
    }


    public init(reading base: UnsafeRawPointer) {
        self.kind     = FSKind(rawValue: base.loadUnaligned(fromByteOffset: 0, as: UInt8.self)) ?? .free
        self.blocks   = base.loadUnaligned(fromByteOffset: 4,  as: UInt32.self)
        self.size     = base.loadUnaligned(fromByteOffset: 8,  as: UInt64.self)
        self.created  = Time(nanoseconds: base.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        self.modified = Time(nanoseconds: base.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
    }


    public func write(to base: UnsafeMutableRawPointer) {
        base.storeBytes(of: kind.rawValue,       toByteOffset: 0,  as: UInt8.self)
        base.storeBytes(of: UInt8(0),            toByteOffset: 1,  as: UInt8.self)
        base.storeBytes(of: UInt16(0),           toByteOffset: 2,  as: UInt16.self)
        base.storeBytes(of: blocks,              toByteOffset: 4,  as: UInt32.self)
        base.storeBytes(of: size,                toByteOffset: 8,  as: UInt64.self)
        base.storeBytes(of: created.nanoseconds, toByteOffset: 16, as: UInt64.self)
        base.storeBytes(of: modified.nanoseconds,toByteOffset: 24, as: UInt64.self)
    }
}
