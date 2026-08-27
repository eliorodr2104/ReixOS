//
//  FSMount.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// What was found on a disk somebody tried to mount.
///
/// Six answers where there used to be two, and the two were the problem: a
/// disk was either mountable or "not formatted", and not formatted led straight
/// to being formatted. So a torn write of the magic, a version this build does
/// not know, and a disk belonging to another system all arrived at the same
/// place, which was `format()`.
///
/// None of these decides anything. Deciding is the caller's, and only one of
/// them - `blank` - is a disk anybody should be willing to write over.
public enum FSMount {

    /// The disk holds this format, at this version, describing this disk.
    case ok

    /// Every byte of block zero is zero.
    ///
    /// The whole block and not just the magic: a superblock whose magic was
    /// lost half way through a write still has the rest of itself, and reading
    /// that as an empty disk is exactly how a torn write turned into an erase.
    case blank

    /// This format, in a version this build does not know how to read.
    ///
    /// The version travels in the last two bytes of the magic, so an older
    /// build meeting a newer disk recognises it as one of ours and refuses it,
    /// rather than seeing an unfamiliar number and calling the disk empty.
    case unsupportedVersion(UInt16)

    /// This format, on a disk larger than this build is declared to work on.
    ///
    /// Refused rather than served slowly, and refused *unread*: a dirty mount runs
    /// a recovery whose cost grows with the square of the disk, and a geometry
    /// nobody has measured is one nobody can say the boot will come back from.
    /// See `FSLayout.maxSupportedBlocksV02`.
    case tooLarge(UInt32)

    /// There is something on this disk, and it is not a file system this build
    /// can mount.
    ///
    /// Both of the ways that happens, because the answer is the same either
    /// way: leave it alone. Either the magic is ours and the rest does not add
    /// up - a torn write, a bad block, a disk that was resized underneath its
    /// superblock - or the magic is not ours at all and the disk belongs to
    /// something else entirely.
    case corrupt

    /// The device would not answer, so nothing is known about what is on it.
    case deviceFailed

    /// The device cannot hold this format at all: too few blocks, or a sector
    /// size a block is not a whole number of.
    case unusable

    /// The device cannot say what a completed write has achieved, so there is no
    /// order to be had on it and this format has nothing else to build on.
    ///
    /// Refused before block zero is even read, because the one write a
    /// successful mount does - the mounted mark - is already a write, and a
    /// volume this build cannot mount read-only is a volume it must not open.
    case durabilityUnknown
}
