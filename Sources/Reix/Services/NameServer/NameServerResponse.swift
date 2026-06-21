//
//  Response.swift
//  ReixOS
//
//  Name Server reply codes (carried in the tag label).
//

import ReixABI

public enum NameServerResponse: UInt32, IPCLabel {
    case ok            = 0
    case ack           = 1
    case errorRegister = 2
    case errorLookup   = 3

    public var message: Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = self.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
