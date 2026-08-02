//
//  Response.swift
//  ReixOS
//
//

import ReixABI

public enum ProcessServerResponse: UInt32, IPCLabel {
    case ok = 0

    /// Nothing was spawned: the request named a program this server does not know.
    ///
    /// A refusal still owes the caller an answer. `call` parks it in
    /// `.blockedOnReply` and only a reply releases it, so staying silent leaves it
    /// there until an unrelated client happens to displace the reply link.
    case errorSpawn = 1

    public func message(for value: UInt32?) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = value ?? self.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
