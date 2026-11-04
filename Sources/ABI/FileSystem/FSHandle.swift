//
//  FSHandle.swift
//  ReixOS
//
//  Created by Eliomar on 23/08/2026.
//

/// How a client names an object in a request.
///
/// A **handle**, and not a badge. The two carry the same two facts - which object
/// and which incarnation of it - and neither carries the third: what a client may
/// do is decided by the capability it is speaking through, never by a number it
/// sends. A handle that carried rights bits would be a client saying what it is
/// allowed to do.
///
/// Thirty-two bits, because that is what a word in a message is. No room is made
/// for rights, so the whole word above the object number is generation - which is
/// what makes the split from `FSBadge` worth having rather than a tidy-up: the
/// eight bits the rights used to take out of *this* word were eight halvings of
/// how many times a slot could be reused.
public struct FSHandle {

    /// Bits the object number occupies, low end of the word.
    public let objectBits: UInt64

    private let objectMask: UInt32
    private let generationMask: UInt32


    public init(objectBits: UInt64) {
        self.objectBits = objectBits

        self.objectMask = objectBits >= 32
            ? UInt32.max
            : UInt32((UInt64(1) << objectBits) - 1)

        self.generationMask = objectBits >= 32
            ? 0
            : UInt32((UInt64(1) << (32 - objectBits)) - 1)
    }


    /// How many times one slot may be reused before a handle for an old
    /// incarnation of it could match a new one.
    public var generationSpan: UInt64 { UInt64(generationMask) &+ 1 }

    /// The highest generation this handle can tell apart from every earlier one.
    public var lastGeneration: UInt32 { generationMask }


    /// The handle for `object` as it is now, at `generation`.
    public func encode(object: UInt32, generation: UInt32) -> UInt32 {
        let slot = (object &+ 1) & objectMask
        let age  = (generation & generationMask) << UInt32(objectBits)

        return slot | age
    }


    /// The object a handle names, or `nil` when it names nothing.
    public func object(of handle: UInt32) -> UInt32? {
        let slot = handle & objectMask
        return slot == 0 ? nil : slot - 1
    }


    /// The incarnation a handle names.
    public func generation(of handle: UInt32) -> UInt32 {
        objectBits >= 32 ? 0 : (handle >> UInt32(objectBits)) & generationMask
    }


    /// A record's generation cut down to what a handle can carry.
    public func fits(_ generation: UInt32) -> UInt32 { generation & generationMask }


    /// Whether `handle` names the incarnation a record at `generation` is.
    public func names(
        generation: UInt32,
        handle    : UInt32
    ) -> Bool { self.generation(of: handle) == fits(generation) }
}
