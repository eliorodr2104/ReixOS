//
//  ConsoleOperation.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

public enum ConsoleOperation: UInt32, IPCLabel {
    case register
    case kick

    public func message(client: UInt32) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = client

        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
