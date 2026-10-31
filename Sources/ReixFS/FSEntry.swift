//
//  FSEntry.swift
//  ReixOS
//
//  Created by Eliomar on 24/08/2026.
//


/// One name in one folder.
///
/// A free slot is one with no name, which is why the length is checked and not
/// the object number: object zero is the root and a perfectly good target.
public struct FSEntry {

    public var object: UInt32
    public var length: UInt8
    public var name  : InlineArray<56, UInt8>

    /// Whether the bytes this entry was read from describe a name a folder may
    /// hold.
    ///
    /// In memory only, like `FSObject.recordEncodingValid`, and for the same
    /// reason. A length past the field is clamped to zero so that nothing reads a
    /// name off the end of the entry, and that clamp made a corrupt entry
    /// indistinguishable from an unused slot: `link` would write over it and
    /// `forEachEntry` would walk straight past it.
    public private(set) var encodingValid: Bool = true

    public init() {
        self.object = 0
        self.length = 0
        self.name   = InlineArray<56, UInt8>(repeating: 0)
    }

    /// Whether the slot holds no name. Says nothing about whether the bytes are
    /// a name at all: see `standing`.
    public var isFree: Bool { length == 0 }


    /// What a slot in a folder block is.
    public enum Standing: Equatable {

        /// A name pointing at an object.
        case named

        /// A slot nobody is using, and one `link` may write into.
        case free

        /// Bytes that are not an entry of this format at all.
        case impossible
    }


    /// Which of the three this slot is.
    public var standing: Standing {
        guard encodingValid else { return .impossible }

        return length == 0 ? .free : .named
    }


    /// Whether `byte` is one a name may be made of.
    ///
    /// The one place the rule lives, so the reader and the writer cannot drift:
    /// no separator, no terminator, nothing unprintable. A name that can contain
    /// a slash is a name that can lie about where it lives.
    static func allowed(_ byte: UInt8) -> Bool {
        byte > 0x20 && byte < 0x7F
            && byte != UInt8(ascii: "/") && byte != UInt8(ascii: ":")
    }


    /// Where an entry's own check lives: the three bytes after the length,
    /// which were padding.
    static let checkOffset = 5
    static let checkWidth  = 3

    /// The check a named entry at `base` should carry.
    ///
    /// Twenty-four bits of the format's one checksum, over the whole entry with
    /// the check itself read as zero. What it is for is a directory block that
    /// rotted while nobody was looking: a mount that trusts its seal never walks
    /// the folders, so the first lookup has to be able to tell.
    static func check(of base: UnsafeRawPointer) -> UInt32 {
        let hash = FSChecksum.over(
            base, count: Int(FSLayout.entrySize), zeroing: checkOffset, width: checkWidth
        )
        return (hash ^ (hash >> 24)) & 0xFF_FFFF
    }

    private static func storedCheck(at base: UnsafeRawPointer) -> UInt32 {
        UInt32(base.loadUnaligned(fromByteOffset: checkOffset,     as: UInt8.self))
            | UInt32(base.loadUnaligned(fromByteOffset: checkOffset + 1, as: UInt8.self)) << 8
            | UInt32(base.loadUnaligned(fromByteOffset: checkOffset + 2, as: UInt8.self)) << 16
    }

    public init(reading base: UnsafeRawPointer) {
        self.object = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

        let raw = base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)

        var name = InlineArray<56, UInt8>(repeating: 0)
        let bytes = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)

        for index in 0..<FSLayout.nameLimit { name[index] = bytes[index] }
        self.name = name

        // Read raw, judged, then clamped, the order a record's extent count
        // takes. See `encodingValid`.
        let long = Int(raw) > FSLayout.nameLimit
        self.length = long ? 0 : raw

        var whole = !long

        for index in 0..<Int(self.length) where !Self.allowed(name[index]) {
            whole = false
        }

        // Free is every byte zero, as `unlink` writes it; a name is one whose
        // check adds up. Anything between is a slot something has damaged.
        if raw == 0 {
            whole = whole && FSChecksum.isZero(base, count: Int(FSLayout.entrySize))
        } else {
            whole = whole && Self.storedCheck(at: base) == Self.check(of: base)
        }

        self.encodingValid = whole
    }


    /// Lays the entry over its 64 bytes, check last. A free entry is all zero.
    public func write(to base: UnsafeMutableRawPointer) {
        guard length > 0 else {
            base.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.entrySize))
            return
        }

        base.storeBytes(of: object, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: length, toByteOffset: 4, as: UInt8.self)
        base.storeBytes(of: UInt8(0), toByteOffset: 5, as: UInt8.self)
        base.storeBytes(of: UInt16(0), toByteOffset: 6, as: UInt16.self)

        let bytes = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
        for index in 0..<FSLayout.nameLimit { bytes[index] = name[index] }

        let check = Self.check(of: base)
        for index in 0..<Self.checkWidth {
            base.storeBytes(
                of: UInt8(truncatingIfNeeded: check >> UInt32(8 * index)),
                toByteOffset: Self.checkOffset + index, as: UInt8.self
            )
        }
    }


    /// Builds an entry, or nil when the name is not one a folder may hold.
    public init?(
               object: UInt32,
        name   text  : UnsafeRawPointer,
        length count : Int
    ) {

        guard count > 0, count <= FSLayout.nameLimit else { return nil }

        let bytes = text.assumingMemoryBound(to: UInt8.self)
        var name  = InlineArray<56, UInt8>(repeating: 0)

        for index in 0..<count {
            let byte = bytes[index]
            guard Self.allowed(byte) else { return nil }

            name[index] = byte
        }

        self.object = object
        self.length = UInt8(count)
        self.name   = name
    }


    /// Whether this entry is named exactly `text`.
    public func matches(
        _      text : UnsafeRawPointer,
        length count: Int
    ) -> Bool {

        guard Int(length) == count else { return false }

        let bytes = text.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count where name[index] != bytes[index] { return false }

        return true
    }
}
