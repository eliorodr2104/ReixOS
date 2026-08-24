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

    public init() {
        self.object = 0
        self.length = 0
        self.name   = InlineArray<56, UInt8>(repeating: 0)
    }

    public var isFree: Bool { length == 0 }


    public init(reading base: UnsafeRawPointer) {
        self.object = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        self.length = base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)

        var name = InlineArray<56, UInt8>(repeating: 0)
        let bytes = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)

        for index in 0..<FSLayout.nameLimit { name[index] = bytes[index] }
        self.name = name

        if Int(self.length) > FSLayout.nameLimit {
            self.length = 0   // corrupt length reads as a free slot
        }
    }


    public func write(to base: UnsafeMutableRawPointer) {
        base.storeBytes(of: object, toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: length, toByteOffset: 4, as: UInt8.self)
        base.storeBytes(of: UInt8(0), toByteOffset: 5, as: UInt8.self)
        base.storeBytes(of: UInt16(0), toByteOffset: 6, as: UInt16.self)

        let bytes = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
        for index in 0..<FSLayout.nameLimit { bytes[index] = name[index] }
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

            // No separator, no terminator, nothing unprintable. A name that can
            // contain a slash is a name that can lie about where it lives.
            guard byte > 0x20, byte < 0x7F, byte != UInt8(ascii: "/"),
                  byte != UInt8(ascii: ":")
            else { return nil }

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
