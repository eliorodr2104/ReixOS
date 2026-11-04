//
//  Operation.swift
//  ReixOS
//
//  Name Server request verbs (carried in the message tag label).
//

import ReixABI

public enum NameServerOperation: UInt32, IPCLabel {
    case register = 0
    case lookup   = 1

    /// Build a request: this verb in the tag, the service id in words[0].
    public func message(for service: Services) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = service.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
