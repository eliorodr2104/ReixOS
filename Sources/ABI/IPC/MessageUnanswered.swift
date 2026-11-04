//
//  MessageUnanswered.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

public extension Message {

    /// Filler for a receive that did not receive anything.
    ///
    /// Not a value any protocol decodes, and no longer pretending to be. A
    /// failed `call` says so through its `Result` and carries no message at all;
    /// what is left needing filler is `receive`, whose failure hands a server
    /// loop something rather than nothing, and the only thing that has to be
    /// true of it is that no operation claims its label. Every server loop reads
    /// the label first and skips what it does not know.
    ///
    /// Every word is `UInt32.max` rather than zero because zero is `ok` in every
    /// status enum in this system, and the top of the range is claimed by none
    /// of them. That is belt and braces, not the mechanism.
    static var unanswered: Message {
        Message(
            tag  : MessageTag(packed: UInt64.max),
            words: InlineArray<4, UInt32>(repeating: UInt32.max)
        )
    }
}
