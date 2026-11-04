//
//  ShmAttachment.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// One client's shared window, as the server that mapped it sees it.
///
/// Six facts, and the sixth is the session discriminator. A server used to know
/// *who* had attached and *where* their page was, so a request it took before an
/// attachment was replaced was indistinguishable from one taken after: same
/// identity, same slot, and a window pointer that had been quietly swapped for
/// somebody else's. The epoch is what tells two attachments of the same client
/// apart, and it is checked at the one moment it matters - the instant before
/// bytes are copied.
///
/// `address` and `grant` are integers here and nothing more. Unmapping a window
/// and dropping a capability are syscalls, so this type never does either: it
/// hands the old attachment back and the server that owns the address space is
/// the one that releases it. That is what keeps the rule testable on a host.
public struct ShmAttachment {

    /// Who attached. The badge the kernel put on the message, never anything the
    /// client said about itself.
    public let identity: UInt32

    /// Which attachment of that client this is. Never reused.
    public let epoch: UInt64

    /// A nonzero client-chosen session token carried by operations that use
    /// this attachment. It separates two live pages from one identity.
    public let token: UInt32

    /// Where the window starts in this server's address space.
    public let address: UInt64

    /// How far it reaches. From `shmPages`, so from the kernel and not from the
    /// client's own account of its grant.
    public let extent: UInt64

    /// The capability the window came in on, held so it can be dropped.
    public let grant: UInt32

    public init(
        identity: UInt32,
        epoch   : UInt64,
        token   : UInt32 = 0,
        address : UInt64,
        extent  : UInt64,
        grant   : UInt32
    ) {
        self.identity = identity
        self.epoch    = epoch
        self.token    = token
        self.address  = address
        self.extent   = extent
        self.grant    = grant
    }


    /// Whether this is still the attachment a request was made against.
    ///
    /// Both halves, and the epoch is the half that does the work: an identity on
    /// its own is satisfied by the same client having attached again, which is
    /// precisely the case where the window a completion was going to be copied
    /// into is a different page.
    public func matches(identity: UInt32, epoch: UInt64) -> Bool {
        self.identity == identity && self.epoch == epoch
    }

    public func matches(identity: UInt32, token: UInt32) -> Bool {
        token != 0 && self.identity == identity && self.token == token
    }


    /// Whether `bytes` starting at `offset` are inside the window.
    ///
    /// The addition is checked, because both numbers are derived from a request:
    /// an offset near the top with a length that carries it round is a range that
    /// every naive `offset + bytes <= extent` accepts.
    public func covers(_ offset: UInt64, _ bytes: UInt64) -> Bool {
        let (end, overflowed) = offset.addingReportingOverflow(bytes)
        return !overflowed && end <= extent
    }


    /// Whether a grant of `pages` is one to accept at all.
    ///
    /// A server that maps whatever it is handed is a server a client can ask to
    /// map anything. The upper bound is how much this server is willing to spend
    /// on one client; the lower bound is that a window of nothing is not a
    /// window, and a server that accepted one would have every request against it
    /// refused after the attach had already been taken.
    public static func accepts(pages: UInt32, atMost limit: UInt32) -> Bool {
        pages >= 1 && pages <= limit
    }


    /// Where attachment numbers come from.
    ///
    /// Monotonic and never reused, which is the whole contract: an epoch handed
    /// out twice is two attachments a completion cannot be told apart by, and
    /// that is the bug this type exists for. Zero is never handed out, so a
    /// zeroed field is not a valid epoch.
    public struct Epochs {

        private var last: UInt64 = 0

        public init() {}

        /// The next attachment number, or nil when there are no more.
        ///
        /// Sixty-four bits is one attachment a nanosecond for five hundred years,
        /// so the nil is unreachable rather than merely unlikely. It is here
        /// because the alternative is a wrap, and a wrap hands out an epoch some
        /// completion still believes in - which is the one outcome this must not
        /// have, however remote.
        public mutating func next() -> UInt64? {
            guard last < UInt64.max else { return nil }

            last += 1
            return last
        }

        /// The last number handed out, or zero when none has been.
        public var current: UInt64 { last }
    }


    /// One attachment at a time, replaced under a rule.
    ///
    /// The rule is the whole type: `install` hands back whatever it displaced,
    /// and there is no other way to put an attachment in. A server cannot
    /// therefore overwrite a window it still has mapped, because overwriting
    /// gives it the old one to unmap - and the one it forgets to unmap is the one
    /// it never sees.
    ///
    /// It was two independent fields, a badge and a pointer, assigned one after
    /// the other. Registering twice replaced both and released neither, so every
    /// registration after the first cost a mapped page and a capability for the
    /// rest of the boot.
    public struct Slot {

        public private(set) var current: ShmAttachment?

        private var epochs = Epochs()

        public init() {}

        /// The number the next attachment will carry, or nil when there are no
        /// more to hand out.
        ///
        /// Taken before anything is mapped, so the one step that cannot be undone
        /// happens after every step that can fail.
        public mutating func nextEpoch() -> UInt64? { epochs.next() }

        /// Puts `attachment` in and hands back what it displaced, which the
        /// caller owes an unmap and a capability drop.
        public mutating func install(_ attachment: ShmAttachment) -> ShmAttachment? {
            let displaced = current
            current = attachment

            return displaced
        }

        /// Takes the attachment out, for a client that has gone.
        public mutating func take() -> ShmAttachment? {
            let held = current
            current = nil

            return held
        }

        /// Whether `identity` is the registered holder of this slot.
        public func held(by identity: UInt32) -> Bool {
            current?.identity == identity
        }

        public func held(by identity: UInt32, token: UInt32) -> Bool {
            current?.matches(identity: identity, token: token) == true
        }

        public func acceptsRegistration(identity: UInt32, currentIsLive: Bool) -> Bool {
            guard let current else { return true }
            return current.identity == identity || !currentIsLive
        }
    }
}
