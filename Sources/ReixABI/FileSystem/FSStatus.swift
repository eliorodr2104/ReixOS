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
}
