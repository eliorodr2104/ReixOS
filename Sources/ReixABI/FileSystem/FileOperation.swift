//
//  FileOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// What a client may ask the file system for.
///
/// The same shape as the block service one level down: names and bytes travel
/// through a page the client attached, messages carry only numbers. A name is
/// bytes like any other, so `open` puts it in the window rather than trying to
/// fit it in four words.
public enum FileOperation: UInt32, IPCLabel {

    /// Hand over the page this client's names and bytes will travel through.
    case attach

    /// What the disk is: free space, and whether it came back dirty. Doubles as
    /// the acknowledgement of `attach`, the same way `geometry` does for a
    /// block device.
    case status

    /// Find a name in a folder. The name is in the window.
    case open

    /// Make something and name it. The name is in the window.
    case create

    /// Unname something and take its space back.
    case remove

    /// Bytes out of an object, into the window.
    case read

    /// Bytes from the window, into an object.
    case write

    /// The nth name in a folder, out into the window.
    case list

    /// Ask for a capability naming something the caller can already reach: a
    /// container, a folder, or a single file.
    ///
    /// This is how a piece of one container is handed to another: not by
    /// telling somebody a number, which they could have guessed, but by giving
    /// them the thing that makes the number mean something. What comes back is
    /// bound to that object and cannot be rebound, because the kernel refuses
    /// to badge an already-badged capability, and may be marked read-only on
    /// the way out.
    case bind

    /// Move room from the caller's container to one directly inside it.
    case grantRoom

    /// The path from the caller's own root down to an object, written out into
    /// the window in the syntax it would be typed in.
    case path

    /// Bytes from the window become the object's whole contents: everything
    /// past the last byte written is dropped.
    ///
    /// A separate operation and not a flag on `write`, because the four words
    /// of a message are spoken for and because the two are different acts.
    /// Writing into the middle of a file keeps the rest; saying what a file now
    /// says does not.
    case replace

    /// Give something a new name, a new folder, or both. Both names are in the
    /// window, the old one first.
    case relocate

    /// What an object is: kind, size, and when it was made and last changed.
    /// The answer goes into the window as an `FSInfo`.
    case info

    /// Rename the machine. The new name is in the window.
    case nameMachine

    /// Mark the disk clean. Nothing is served afterwards.
    case unmount

    /// Put a scattered object back into one run of blocks.
    case compact

    /// Read the whole disk and say what does not add up, changing nothing.
    ///
    /// The deep one, and it is a request rather than something a mount does:
    /// walking every name in every folder is a great many more reads than a
    /// boot after a power cut should pay for. What a mount runs is the block
    /// map alone.
    case scrub

    /// Claim an object, so that nobody else may change it until it is let go.
    case lock

    /// Let go of a claim.
    case unlock

    /// The folder above an object, stopping at the caller's own root.
    ///
    /// Going up is a question only the file system can answer: the parent link
    /// is on the disk and a client has no way to read it. Asking at the root
    /// answers the root, so walking up stops at the edge of what the caller
    /// holds instead of failing there.
    case up


    /// A `relocate` request: two folders, and the two names in the window with
    /// the old one first.
    public static func relocating(
        from   folder   : UInt32,
               length   : UInt32,
        to     target   : UInt32,
        length newLength: UInt32
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = folder
        words[1] = length
        words[2] = target
        words[3] = newLength

        return Message(
            tag  : MessageTag(FileOperation.relocate, length: 4),
            words: words
        )
    }


    /// A request naming an object and a stretch of it.
    public func transfer(
        object: UInt32,
        offset: UInt64,
        count : UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = object
        words[1] = UInt32(truncatingIfNeeded: offset)
        words[2] = UInt32(truncatingIfNeeded: offset >> 32)
        words[3] = count

        return Message(
            tag : MessageTag(self, length: 4),
            words: words
        )
    }

    public static func offset(of message: Message) -> UInt64 {
        UInt64(message.words[1]) | (UInt64(message.words[2]) << 32)
    }


    /// A request naming something inside a folder, with the name in the window.
    ///
    /// `room` is the blocks a new container is to be given, out of the folder's
    /// own. It is ignored for everything that is not a container.
    public func named(
        folder: UInt32,
        length: UInt32,
        kind  : FSKind = .free,
        room  : UInt32 = 0
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = folder
        words[1] = length
        words[2] = UInt32(kind.rawValue)
        words[3] = room

        return Message(tag: MessageTag(self, length: 4), words: words)
    }


    /// An `attach` request, saying how big the granted region is.
    public static func attaching(pages: UInt32) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = pages

        return Message(tag: MessageTag(FileOperation.attach, length: 1), words: words)
    }


    /// How it went, and one number besides: bytes moved, or the object found.
    public static func answer(
        _ status: FSStatus,
          value : UInt32 = 0
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = value

        return Message(tag: MessageTag(FileOperation.status, length: 2), words: words)
    }


    /// How it went, and the object it is about.
    public static func describing(
        _ status: FSStatus,
          object  : UInt32,
          kind    : FSKind,
          size    : UInt64
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = object
        words[2] = UInt32(truncatingIfNeeded: size)
        words[3] = UInt32(truncatingIfNeeded: size >> 32) | (UInt32(kind.rawValue) << 24)

        return Message(
            tag  : MessageTag(FileOperation.open, length: 4),
            words: words
        )
    }

    /// The object a `describing` answer is about.
    ///
    /// The kind rides in the top byte of the size's high half, which costs a
    /// file system a size limit of 2^56 bytes. On a machine whose disk is
    /// sixteen megabytes that is not the constraint worth spending a word on.
    public static func described(_ message: Message)
    -> (object: UInt32, kind: FSKind, size: UInt64) {

        let high = message.words[3]

        return (
            message.words[1],
            FSKind(rawValue: UInt8(truncatingIfNeeded: high >> 24)) ?? .free,
            UInt64(message.words[2]) | (UInt64(high & 0x00FF_FFFF) << 32)
        )
    }


    /// The answer to `list`: how it went, what the name refers to, how long the
    /// name written into the window is, and where to carry on from.
    ///
    /// A shape of its own rather than `describing` with the size reused for the
    /// length. Two meanings in one word is how a wire format starts lying.
    public static func listing(
        _ status: FSStatus,
          object: UInt32,
          kind  : FSKind,
          length: UInt32,
          next  : UInt32
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = object
        words[2] = length
        words[3] = (UInt32(kind.rawValue) << 24) | (next & 0x00FF_FFFF)

        return Message(
            tag  : MessageTag(FileOperation.list, length: 4),
            words: words
        )
    }

    /// Where a listing carries on from. Sixteen million entries in one folder
    /// is not a limit this disk will reach before the object table does.
    public static func listedNext(_ message: Message) -> UInt32 {
        message.words[3] & 0x00FF_FFFF
    }

    /// How long the name in the window is, from a `listing` answer.
    public static func listedLength(_ message: Message) -> Int {
        Int(message.words[2])
    }


    /// The answer to `status`: how it went, then what the caller's own
    /// container looks like.
    ///
    /// The root comes back on every attach rather than being told to the client
    /// beforehand, because the client does not get to choose it. It is whatever
    /// the capability it used says it is.
    public static func standing(
        root       : UInt32,
        free       : UInt32,
        used       : UInt32,
        dirty      : Bool,
        quarantined: Bool = false
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = FSStatus.ok.rawValue
        words[1] = free

        // Two facts about the state of the disk in one word, because the four
        // words are spoken for and neither needs more than a bit.
        words[2] = (dirty ? 1 : 0) | (quarantined ? 2 : 0)
        words[3] = root

        return Message(tag: MessageTag(FileOperation.status, length: 4), words: words)
    }


    /// The status word every reply starts with.
    public static func status(of message: Message) -> FSStatus {
        FSStatus(rawValue: message.words[0]) ?? .deviceFailed
    }


    /// What the capability a request arrived through may do.
    ///
    /// The part of a badge that does not depend on the disk, so it is the one
    /// thing readable without knowing which disk the badge is about.
    public static func rights(badge: UInt32) -> FSRights {
        FSRights(rawValue: (badge >> FSBadge.rightsShift) & FSRights.everything.rawValue)
    }
}
