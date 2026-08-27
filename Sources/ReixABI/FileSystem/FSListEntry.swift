//
//  FSListEntry.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// One name, as it travels back from a listing.
///
/// Sixty-four bytes, the same width as the entry on the disk, so a page of the
/// client's window holds sixty-four of them and a listing of a folder is one
/// round trip rather than one per name. That was the cost worth removing: a
/// listing of ten names was ten calls and ten reads of the same directory block,
/// and the tenth name was answered by a scan that started at the first.
///
/// ```
/// 0...3   the object, as a handle
/// 4       kind
/// 5       name length, at most fifty-six
/// 6...7   reserved, written zero
/// 8...63  the name, no terminator
/// ```
///
/// The reserved pair is written zero and never read, which is what makes it
/// usable later: a reader that skipped it cannot be broken by a writer that
/// starts filling it.
public struct FSListEntry {

    /// Bytes one entry takes on the wire.
    public static let width = 64

    /// The most a listing will answer in one go, whatever the window allows.
    ///
    /// Two hundred and fifty-six entries is sixteen kilobytes, which is four
    /// pages: past that a client is asking the server to walk an unbounded amount
    /// of disk inside one request, and a request that cannot be bounded is a
    /// server that can be made to stop answering anybody else.
    public static let batchLimit = 256

    /// The object this name reaches.
    ///
    /// **Two owners, at two moments.** The file system writes the raw object
    /// index here, because that is what a directory entry holds; the server then
    /// replaces it with a generation-aware handle before the reply goes out, for
    /// the reason handles exist at all - an index that outlives the object it
    /// named comes to name a different one. A client only ever sees the handle.
    public var reference: UInt32

    public var kind  : FSKind
    public var length: UInt8
    public var name  : InlineArray<56, UInt8>


    public init(
        reference: UInt32 = 0,
        kind     : FSKind = .free,
        length   : UInt8  = 0,
        name     : InlineArray<56, UInt8> = InlineArray<56, UInt8>(repeating: 0)
    ) {
        self.reference = reference
        self.kind      = kind
        self.length    = length
        self.name      = name
    }


    public init(reading base: UnsafeRawPointer) {
        self.reference = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

        self.kind = FSKind(
            rawValue: base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
        ) ?? .free

        let raw = base.loadUnaligned(fromByteOffset: 5, as: UInt8.self)

        // A length past the field is not a length. Read as an empty name rather
        // than as a name that runs off the end of the entry, because the bytes
        // came out of a window somebody else can write.
        self.length = Int(raw) <= 56 ? raw : 0

        var letters = InlineArray<56, UInt8>(repeating: 0)
        let bytes   = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)

        for index in 0..<56 { letters[index] = bytes[index] }
        self.name = letters
    }


    public func write(to base: UnsafeMutableRawPointer) {
        base.storeBytes(of: reference,     toByteOffset: 0, as: UInt32.self)
        base.storeBytes(of: kind.rawValue, toByteOffset: 4, as: UInt8.self)
        base.storeBytes(of: length,        toByteOffset: 5, as: UInt8.self)
        base.storeBytes(of: UInt16(0),     toByteOffset: 6, as: UInt16.self)

        let bytes = base.advanced(by: 8).assumingMemoryBound(to: UInt8.self)
        for index in 0..<56 { bytes[index] = name[index] }
    }


    /// Replaces the object index with the handle a client is to be given.
    ///
    /// Written straight into the wire bytes, so the server does not have to
    /// decode and re-encode a whole entry to change one word.
    public static func rebadge(_ base: UnsafeMutableRawPointer, _ handle: UInt32) {
        base.storeBytes(of: handle, toByteOffset: 0, as: UInt32.self)
    }

    /// The object index a not-yet-rebadged entry holds.
    public static func reference(of base: UnsafeRawPointer) -> UInt32 {
        base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
    }
}
