//
//  ConsoleOperation.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

public enum ConsoleOperation: UInt32, IPCLabel {
    case register
    case kick
    case flush

    /// Write out the caller's ring even where no line has closed.
    ///
    /// The console emits whole lines, so two processes printing at once cannot
    /// shred each other's output. A terminal is the one writer that must be
    /// seen before its line ends: a prompt has no newline, and neither does a
    /// character being echoed under the cursor. Only the caller's own ring is
    /// drained this way, so nobody else's line is broken open on its behalf.
    case drainPartial

    /// Builds a request (or reply) for this operation.
    ///
    /// The payload never carries the caller's identity: the server keys clients
    /// on `request.badge`, which the kernel reads off the sending process itself
    /// and a client cannot choose. A self-declared id would let anybody register
    /// a ring in another client's name, or flush somebody else's ring.
    ///
    /// The one word is therefore operation-specific: `register` states how many
    /// pages the granted region spans, the `flush` reply carries a
    /// `ConsoleStatus`, `kick` uses none.
    public func message(word0: UInt32 = 0) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = word0

        let tag = MessageTag(self, length: 1)
        return Message(tag: tag, words: words)
    }
}
