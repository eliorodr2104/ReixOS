//
//  FSBadge.swift
//  ReixOS
//
//  Created by Eliomar on 23/08/2026.
//

/// How a file system capability says what it names.
///
/// One session word, stamped by the kernel on delivery, carrying three things:
/// what the holder may do, which object it names, and **which incarnation of that
/// object**.
///
/// The third is why this type exists rather than a pair of functions. A table
/// slot outlives the objects that pass through it: remove the file at slot
/// twelve, make another, and the next `create` may be handed slot twelve. A
/// capability that said only "twelve" would then name a file it was never given
/// - a different file, possibly in somebody else's container. So the badge names
/// a slot *and* the generation of it, and both are checked. See
/// `FSObject.generation`.
///
/// **Sixty-four bits now, and that is what this type is about.** It was
/// thirty-two, shared three ways: eight for the rights, as many as the disk
/// needed for the object number, and whatever was left for the generation. On a
/// sixteen megabyte disk that left fourteen bits, which is sixteen thousand
/// removals of one slot before an old capability could match a new object. Not a
/// theoretical number - a file created and removed in a loop reaches it in
/// minutes.
///
/// The session register is sixty-four bits wide, so the generation now gets
/// thirty-two of them whatever the disk's size, and the object number is not
/// competing with it. What is left is not a wider ceiling but *no* ceiling: see
/// `generationSpan` and `FSObject.retired`, because when a slot does reach the
/// end it is taken out of use rather than wrapped.
///
/// Constructed from an object count rather than being a namespace of static
/// functions, so that encoding or reading a badge without saying which disk it
/// belongs to is not something that can be written.
public struct FSBadge {

    /// Where the rights sit: the top eight bits of the session word.
    static let rightsShift: UInt64 = 64 - UInt64(FSRights.width)

    /// Bits the object number occupies, low end of the word.
    public let objectBits: UInt64

    private let objectMask: UInt64
    private let generationMask: UInt64


    /// The layout for a disk holding `objectCount` object slots.
    public init(objectCount: UInt32) {

        // Enough bits to hold `objectCount` itself, because the object is
        // stored plus one: a badge of zero means "no badge" to the kernel and
        // the machine's own container is object zero.
        var bits  = UInt64(0)
        var reach = UInt64(0)

        while reach < UInt64(objectCount), bits < Self.rightsShift {
            bits  += 1
            reach  = (reach << 1) | 1
        }

        self.objectBits = bits
        self.objectMask = reach

        // What is left between the object number and the rights, capped at
        // thirty-two: the *handle* carries the same generation in a
        // thirty-two bit word, and a generation the badge can hold but the
        // handle cannot is a generation that fails one of the two comparisons
        // every request makes. See `FSHandle`.
        let room = bits >= Self.rightsShift ? 0 : Self.rightsShift - bits
        let span = room > 32 ? 32 : room

        self.generationMask = span == 0 ? 0 : (UInt64(1) << span) - 1
    }


    /// How many times one slot may be reused before a badge for an old
    /// incarnation of it could match a new one.
    ///
    /// The ABA distance, as a number somebody can look at - and now the *number
    /// of reuses a slot is allowed*, rather than the point at which it silently
    /// starts again. A slot that reaches it is retired instead. See
    /// `FSObject.retired`.
    public var generationSpan: UInt64 { generationMask &+ 1 }

    /// The highest generation this badge can tell apart from every earlier one.
    public var lastGeneration: UInt32 {
        generationMask >= UInt64(UInt32.max)
            ? UInt32.max
            : UInt32(generationMask)
    }


    /// The badge for `object` as it is now, at `generation`, held with `rights`.
    public func encode(
        object    : UInt32,
        generation: UInt32,
        rights    : FSRights
    ) -> UInt64 {

        let slot = (UInt64(object) &+ 1) & objectMask
        let age  = (UInt64(generation) & generationMask) << objectBits
        let may  = UInt64(rights.rawValue & FSRights.everything.rawValue) << Self.rightsShift

        return slot | age | may
    }


    /// The object a badge names, or `nil` when it names nothing.
    ///
    /// `nil` is what an unbadged capability looks like, and what a process
    /// holding no view of the disk gets.
    public func object(of badge: UInt64) -> UInt32? {
        let slot = badge & objectMask
        return slot == 0 ? nil : UInt32(truncatingIfNeeded: slot - 1)
    }


    /// The incarnation a badge names, to be compared against the record's own.
    public func generation(of badge: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (badge >> objectBits) & generationMask)
    }


    /// A record's generation cut down to what a badge can carry.
    ///
    /// The comparison is made on this rather than on the whole counter. It is
    /// still a cut, but the number it cuts to is now the one a slot is never
    /// allowed to pass: a record whose generation reached `lastGeneration` is
    /// retired rather than counted round, so two different incarnations of one
    /// slot cannot arrive at the same cut value.
    public func fits(_ generation: UInt32) -> UInt32 {
        UInt32(truncatingIfNeeded: UInt64(generation) & generationMask)
    }


    /// Whether `badge` names the incarnation a record at `generation` is.
    ///
    /// Takes the number rather than the record, because a record is a thing the
    /// file system knows about and this word is all the wire format does.
    public func names(
        generation: UInt32,
        badge     : UInt64

    ) -> Bool { self.generation(of: badge) == fits(generation) }


    /// The handle layout that goes with this badge layout.
    ///
    /// The two are not the same encoding and used to be. A handle travels in a
    /// message word, which is thirty-two bits, and a badge travels in the session
    /// register, which is sixty-four: making them one encoding meant the badge was
    /// as narrow as the handle, and the generation paid for it.
    public var handles: FSHandle { FSHandle(objectBits: objectBits) }
}
