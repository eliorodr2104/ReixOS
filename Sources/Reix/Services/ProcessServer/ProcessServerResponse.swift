//
//  Response.swift
//  ReixOS
//
//  Process Server reply codes (carried in the tag label).
//

import ReixABI

public enum ProcessServerResponse: UInt32, IPCLabel {
    case ok = 0

    public func message(for value: UInt32?) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = value ?? self.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
