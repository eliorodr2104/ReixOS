//
//  TerminalOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// What a client asks the terminal for.
public enum TerminalOperation: UInt32, IPCLabel {

    /// Hand over the page used for terminal events and render patches. One
    /// page, granted with the request.
    case register

    /// Ask whether this caller is registered.
    ///
    /// A register carries a capability, and a message that carries one has no
    /// reply, so the acknowledgement is a question of its own. Same shape as the
    /// console client's, which confirms with a flush.
    case status

    /// Block for one protocol-owned input event. A zero payload length selects
    /// this event form; the legacy prompt/complete-line form remains accepted
    /// for older userland clients during the protocol transition.
    case readLine

    /// Apply one structured render patch or present one shell text frame.
    case present

    public func message(
        word0: UInt32  = 0,
        word1: UInt32? = nil
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = word0
        if let word1 { words[1] = word1 }

        return Message(
            tag  : MessageTag(self, length: word1 == nil ? 1 : 2),
            words: words
        )
    }
}
