//
//  FSStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// How a file system request ended.
public enum FSStatus: UInt32 {

    case ok = 0

    /// The disk would not answer, or answered with a refusal of its own.
    case deviceFailed

    /// The disk holds no file system this build understands.
    case notFormatted

    /// The object asked for is not there, or the name is not in that folder.
    case notFound

    /// A name that is already taken.
    case exists

    /// The name is empty, too long, or holds a character a name may not.
    case badName

    /// The operation asks something of an object its kind cannot do: reading
    /// bytes from a folder, listing a file.
    case wrongKind

    /// The disk is full, or the object table is.
    case noSpace

    /// A folder that still has something in it.
    case notEmpty

    /// More extents than an object can record. The file is too scattered, not
    /// too big.
    case tooFragmented

    /// The capability this request arrived through does not carry the right this
    /// operation needs.
    ///
    /// Named for the common case rather than for the whole of it: it is the
    /// answer for a reader that tried to write, and equally for a tenant that
    /// tried to unmount the volume or move room between containers. What a
    /// capability may do is a set of rights now, not one bit, so there are eight
    /// ways to arrive here instead of one. See `FSRights`.
    ///
    /// Distinct from `notFound` on purpose, and it is the one refusal that is
    /// allowed to be informative: the holder was given this thing deliberately,
    /// so telling it what the thing does not let it do reveals nothing it was
    /// not already told by being given it.
    case readOnly

    /// Somebody else is in the middle of writing this, and said so.
    ///
    /// Not a lock the file system takes on its own: a lease a client asked for.
    /// A write of one request is already indivisible; this is for the writes
    /// that take several, where "indivisible" has to be claimed out loud.
    case busy

    /// The disk said something impossible, so nothing more will be written to
    /// it.
    ///
    /// Not a refusal of this request in particular: the volume is held apart
    /// from that moment on, readable and not writable, because a disk that has
    /// contradicted itself once is a disk whose next write could be the one that
    /// makes the damage unrecoverable.
    case quarantined

    /// The request never got an answer, or what came back was not shaped like
    /// one, so there is nothing on the other end of that capability worth
    /// asking again.
    ///
    /// The one case here no server ever sends. A client *sets* it, on the branch
    /// where the transport told it the exchange did not happen - and setting it
    /// is the point. It used to be a reserved number that a failed reply's words
    /// happened to decode to, which made a transport failure a value in this
    /// protocol's status enum and left every future protocol owing that number
    /// to a layer it knows nothing about.
    case unreachable

    /// A change to the disk's own bookkeeping was attempted with no transaction
    /// open.
    ///
    /// Never reachable from a client: it is the file system refusing itself. Every
    /// mutation opens a transaction and every structural write goes through one,
    /// so this is what a mutation added later without one would get - a refusal
    /// at the door instead of a write that quietly skips the journal.
    case noTransaction

    /// The operation would change more structural blocks than one transaction
    /// holds, so it was refused rather than committed in halves.
    ///
    /// Not `noSpace`: there is room on the disk. What there is not room for is the
    /// *change*, in a journal that holds sixteen block images - and a transaction
    /// that can be truncated is not a transaction. Nothing this format does today
    /// gets near sixteen, so this is a refusal that says the design has met a
    /// case it was not sized for rather than one a client can provoke.
    case tooManyChanges

    /// The disk underneath cannot say what a completed write has achieved, and
    /// this format has nothing but that to build crash safety out of.
    ///
    /// The answer to a barrier that cannot be asked for, and the reason `format`
    /// refuses a disk before writing a byte to it. Distinct from `deviceFailed`
    /// on purpose: nothing has gone wrong, the device is answering perfectly
    /// well, and what it is saying is that no ordering claim about it is true.
    case durabilityUnknown

    /// The tree would be deeper than a walk up the parent chain is allowed to be.
    ///
    /// Every containment check in this file system is a walk up that chain, and
    /// the walk is bounded so that a loop on a damaged disk costs a refusal
    /// rather than a hang. A tree deeper than the bound is therefore a tree parts
    /// of which nothing can decide the containment of, so the depth is enforced
    /// where it grows - `create`, and `relocate` - rather than discovered later
    /// by a walk that gives up.
    ///
    /// Not `noSpace`: there is room on the disk, and a client that read this as
    /// "full" would go and delete things, which would not help.
    case tooDeep

    /// A write that would start past the end of the file.
    ///
    /// **v02 files are dense.** A write may overwrite bytes the file already has
    /// or carry straight on from its last one, and nothing else: an offset beyond
    /// the size is a hole, and this format does not have holes.
    ///
    /// It used to fill them in - allocate the blocks of the gap and write a page
    /// of zeros into each - which made a one-byte write at eight megabytes an
    /// eight-megabyte write, on a machine with four of RAM, for a shape the format
    /// has no way to record. Saying no is the honest version of the same answer,
    /// and it is a different answer from every other refusal here: the disk is
    /// fine, the request is well formed, and the file simply is not that long.
    ///
    /// Its own case rather than `deviceFailed` or `noSpace`, because a client that
    /// read either of those would look for a broken disk or delete something to
    /// make room. What this asks for is a write at the end instead.
    case pastTheEnd

    /// The disk is larger than this version of the format is declared to work on.
    ///
    /// Not a disk that is broken and not one that is full: it is a geometry whose
    /// recovery has not been measured, and this build will not format one rather
    /// than lay a file system down whose dirty mount takes an unknown amount of
    /// time. See `FSLayout.maxSupportedBlocksV02`.
    case tooManyBlocks

    /// The disk contains more containers than version 02 can index safely.
    case unsupportedCapacity

    /// A caller's destination cannot hold the complete typed result.
    case bufferTooSmall
}
