//
//  BlockOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//


/// What a client may ask a block server for.
///
/// The bytes never travel in the message. A request names sectors and the
/// server moves them through the page the client attached, which is why
/// `attach` comes first and why everything else answers `notAttached` until it
/// has.
public enum BlockOperation: UInt32, IPCLabel {

    /// Hand the server the shared page this client's sectors will pass through.
    /// The page arrives as the grant; the word says how many pages it is.
    case attach

    /// Ask what the device is. Doubles as the acknowledgement of `attach`,
    /// which is why there is no reply to `attach` itself: a geometry that comes
    /// back `ok` is the only proof of attachment worth having.
    case geometry

    case read
    case write

    /// Start a transfer and do not answer it. **Sent, never called.**
    ///
    /// The other half of `collect`, and together they are the only way one client
    /// gets more than one request in flight. `read` and `write` are calls, and a
    /// call parks its caller: a process waiting for an answer cannot ask a second
    /// question, so a single-threaded client could keep exactly one request
    /// going however deep the queue underneath it was.
    ///
    /// `words[3]` is the slot, which names the request *and* the page of the
    /// client's window its bytes travel through. Two numbers would be two
    /// numbers that have to agree.
    case begin

    /// Ask for one finished transfer. **Called.**
    ///
    /// Answers as soon as one is done, and waits if none is - the server holds
    /// the call rather than refusing it, which is what makes a client's collect
    /// loop a loop and not a poll. A client with nothing outstanding is answered
    /// at once with `BlockQueue.none`, because waiting for a completion that was
    /// never asked for is a hang.
    case collect

    /// Take the volume. The holder is the only process whose writes the server
    /// will carry out, and there is only ever one holder, so a file system that
    /// has mounted a disk is a file system nobody can write underneath.
    case mount

    /// Give the volume back, which is what makes the disk quiet again. Until
    /// this arrives a read-only view is told the volume is held rather than
    /// being handed blocks that are mid-change.
    case unmount

    /// Put everything already accepted on the medium, and order it before
    /// anything sent afterwards.
    ///
    /// The barrier the layer above needs to mean what it says. A file system
    /// that writes a record before releasing the blocks it stopped pointing at
    /// has only expressed a wish about a write cache until one of these lands
    /// between the two.
    case flush

    /// Whoever held the volume is gone, so everything it left behind can be let
    /// go: the claim, the window still mapped in the server, and the page still
    /// granted to it.
    ///
    /// Not the same statement as `unmount`, which is a holder saying it has
    /// finished. This one is somebody else saying the holder no longer exists,
    /// so only a warden may make it, and a warden may make no other.
    case reclaim
    
    
    private static let writingBit: UInt32 = 0x8000_0000
    
    /// Which bit of the sector-size word says a write is not on the medium until
    /// a flush says so.
    private static let needsFlushBit: UInt32 = 0x8000_0000
    
    /// A request with nothing to say beyond which one it is.
    public var request: Message {
        Message(
            tag  : MessageTag(self, length: 0),
            words: InlineArray<4, UInt32>(repeating: 0)
        )
    }
    

    /// A request naming a run of sectors.
    public func transfer(
        count : UInt32,
        sector: UInt64
    ) -> Message {
    
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = count
        words[1] = UInt32(truncatingIfNeeded: sector)
        words[2] = UInt32(truncatingIfNeeded: sector >> 32)

        return Message(tag: MessageTag(self, length: 3), words: words)
    }

    /// A `begin`: a run of sectors, and the slot it belongs to.
    public static func beginning(
        count : UInt32,
        sector: UInt64,
        slot  : UInt32,
        write : Bool
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = count
        words[1] = UInt32(truncatingIfNeeded: sector)
        words[2] = UInt32(truncatingIfNeeded: sector >> 32)

        // The direction rides in the top bit of the slot. A slot is one of four
        // and the word is thirty-two bits wide, so there was never going to be a
        // shortage - and a separate word there is not.
        words[3] = slot | (write ? Self.writingBit : 0)

        return Message(tag: MessageTag(BlockOperation.begin, length: 4), words: words)
    }

    /// The slot a `begin` names, and whether it is a write.
    public static func begun(_ message: Message) -> (slot: UInt32, write: Bool) {
        (message.words[3] & ~Self.writingBit, message.words[3] & Self.writingBit != 0)
    }

    /// The answer to `collect`: how it went, and which slot it was about.
    public static func collected(_ status: BlockStatus, slot: UInt32) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = slot

        return Message(tag: MessageTag(BlockOperation.read, length: 2), words: words)
    }

    /// The slot a `collect` answer is about.
    public static func slot(of message: Message) -> UInt32 {
        message.words[1]
    }

    /// The sector a `transfer` request names, rebuilt from its two halves.
    public static func sector(of message: Message) -> UInt64 {
        UInt64(message.words[1]) | (UInt64(message.words[2]) << 32)
    }

    /// An `attach` request, saying how big the granted region is.
    public static func attaching(pages: UInt32) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = pages

        return Message(tag: MessageTag(BlockOperation.attach, length: 1), words: words)
    }

    /// A plain answer: how it went and nothing else.
    public static func answer(_ status: BlockStatus) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue

        return Message(tag: MessageTag(BlockOperation.read, length: 1), words: words)
    }

    /// The answer to `geometry`: how it went, then what the device is.
    ///
    /// No run limit here. How many sectors fit in one call is a fact about the
    /// window the *client* attached, so the client already knows it and asking
    /// would be asking somebody else about your own page.
    public static func geometry(
        sectorSize : UInt32,
        sectorCount: UInt64,
        durability : BlockDurability = .onFlush
    ) -> Message {

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = BlockStatus.ok.rawValue

        // The sector size and one fact about what a write means, in one word.
        // A sector size is a power of two and a small one - four thousand and
        // ninety-six is a large disk's answer - so the top bit was never going
        // to be part of a size, and the four words were already spoken for.
        words[1] = sectorSize | (durability == .onFlush ? Self.needsFlushBit : 0)

        words[2] = UInt32(truncatingIfNeeded: sectorCount)
        words[3] = UInt32(truncatingIfNeeded: sectorCount >> 32)

        return Message(tag: MessageTag(BlockOperation.geometry, length: 4), words: words)
    }

    /// The device the `geometry` answer describes.
    public static func device(of message: Message) -> (
        sectorSize : UInt64,
        sectorCount: UInt64,
        durability : BlockDurability
    ) {
        (
            UInt64(message.words[1] & ~Self.needsFlushBit),
            UInt64(message.words[2]) | (UInt64(message.words[3]) << 32),
            message.words[1] & Self.needsFlushBit != 0 ? .onFlush : .onCompletion
        )
    }

    /// The status word every reply starts with.
    public static func status(of message: Message) -> BlockStatus {
        BlockStatus(rawValue: message.words[0]) ?? .unreachable
    }


    /// How a block capability says its holder may only look.
    ///
    /// One word, stamped by the kernel when the capability is derived, so which
    /// view of the disk a request came through is not something the request can
    /// claim. There are exactly two views: the disk, unbadged, held by whoever
    /// was handed it; and a read-only one for looking, which anybody may be
    /// given because it cannot change a byte.
    public enum Badge {

        /// Unbadged: the disk. Its holder may claim the volume and, having
        /// claimed it, write it.
        public static let disk: UInt32 = 0

        /// May look, never touch, and only at a disk nobody is holding.
        public static let readOnly: UInt32 = 1

        /// May say that the holder of the volume is gone, and nothing else at
        /// all: a warden cannot read a byte, write one, or take the volume. It
        /// is the authority to end a claim, held apart from the disk on purpose,
        /// because the process that knows a mount has died is not the process
        /// that was doing the mounting.
        public static let warden: UInt32 = 2
    }
}
