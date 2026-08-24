//
//  FSBadge.swift
//  ReixOS
//
//  Created by Eliomar on 23/08/2026.
//


/// How a file system capability says what it names.
///
/// One word, stamped by the kernel on delivery, carrying three things: what the
/// holder may do, which object it names, and **which incarnation of that
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
/// How the twenty-four bits under the rights are split is not a constant,
/// because the disk decides how many object numbers there are. The table takes
/// what it needs and the generation gets the rest, which degrades the right way:
/// a small disk gets many removals per slot before the count comes round, a
/// large one gets fewer, and neither has an arbitrary ceiling written into it.
///
/// The rights cost the generation eight of those bits, and that is a real price
/// rather than a rounding: it is eight halvings of how many times one slot may
/// be reused before an old capability could match again. Worth paying, because
/// the alternative was a single bit that made every writer an administrator, and
/// worth knowing, which is what `generationSpan` is for.
///
/// Constructed from an object count rather than being a namespace of static
/// functions, so that encoding or reading a badge without saying which disk it
/// belongs to is not something that can be written.
public struct FSBadge {

    /// Where the rights sit: the top of the word, above everything the disk
    /// decides the width of.
    static let rightsShift: UInt32 = 32 - FSRights.width

    /// Bits the object number occupies, low end of the word.
    public let objectBits: UInt32

    private let objectMask: UInt32
    private let generationMask: UInt32


    /// The layout for a disk holding `objectCount` object slots.
    public init(objectCount: UInt32) {

        // Enough bits to hold `objectCount` itself, because the object is
        // stored plus one: a badge of zero means "no badge" to the kernel and
        // the machine's own container is object zero.
        var bits = UInt32(0)
        var reach = UInt32(0)

        while reach < objectCount, bits < Self.rightsShift {
            bits  += 1
            reach  = (reach << 1) | 1
        }

        self.objectBits     = bits
        self.objectMask     = reach
        self.generationMask = bits >= Self.rightsShift
                            ? 0
                            : (UInt32(1) << (Self.rightsShift - bits)) - 1
    }


    /// How many times one slot may be reused before a badge for an old
    /// incarnation of it could match a new one.
    ///
    /// The ABA distance, as a number somebody can look at. It is what the rights
    /// were bought with.
    public var generationSpan: UInt32 { generationMask &+ 1 }


    /// The badge for `object` as it is now, at `generation`, held with `rights`.
    public func encode(
        object    : UInt32,
        generation: UInt32,
        rights    : FSRights
    ) -> UInt32 {

        let slot = (object &+ 1) & objectMask
        let age  = (generation & generationMask) << objectBits
        let may  = (rights.rawValue & FSRights.everything.rawValue) << Self.rightsShift

        return slot | age | may
    }


    /// The object a badge names, or `nil` when it names nothing.
    ///
    /// `nil` is what an unbadged capability looks like, and what a process
    /// holding no view of the disk gets.
    public func object(of badge: UInt32) -> UInt32? {
        let slot = badge & objectMask
        return slot == 0 ? nil : slot - 1
    }


    /// The incarnation a badge names, to be compared against the record's own.
    public func generation(of badge: UInt32) -> UInt32 {
        (badge >> objectBits) & generationMask
    }


    /// A record's generation cut down to what a badge can carry.
    ///
    /// The comparison is made on this rather than on the whole counter, so it is
    /// the *badge's* width that says how many removals of one slot it takes
    /// before an old capability could match again. On a disk of five hundred
    /// slots that is two million; the number is worth knowing rather than worth
    /// widening, because a word is a word.
    public func fits(_ generation: UInt32) -> UInt32 {
        generation & generationMask
    }


    /// Whether `badge` names the incarnation a record at `generation` is.
    ///
    /// Takes the number rather than the record, because a record is a thing the
    /// file system knows about and this word is all the wire format does.
    public func names(
        generation: UInt32,
        badge     : UInt32
    
    ) -> Bool { self.generation(of: badge) == fits(generation) }


    /// The handle a client is given for an object, and the same word it sends
    /// back in every request about it.
    ///
    /// The same encoding as a badge carrying no rights at all, and on purpose:
    /// an object number that travels in a message has exactly the problem a
    /// badge had. What a client may do is decided by the capability it is
    /// speaking through, never by a number it sends, so a handle says nothing
    /// about rights and is never read for them. A client is answered "twelve" by `open`, somebody else removes
    /// twelve and creates a new thing, and the client's next request lands on
    /// it. Narrower than the badge hole - containment still keeps it inside the
    /// caller's own container - but the same mistake, so the same word.
    ///
    /// It fits with no room made for it: the object word in every message is
    /// thirty-two bits wide and a disk of five hundred slots needs ten of them.
    ///
    /// Read back with `object(of:)` and checked with `names(generation:badge:)`,
    /// the same two calls a badge takes.
    public func handle(
        object    : UInt32,
        generation: UInt32
        
    ) -> UInt32 { encode(object: object, generation: generation, rights: []) }
}
