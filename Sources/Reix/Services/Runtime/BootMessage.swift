//
//  BootMessage.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public enum BootMessage: UInt32, IPCLabel {
    case announce

    public var message: Message {
        Message(
            tag  : MessageTag(self, length: 0),
            words: InlineArray<4, UInt32>(repeating: 0)
        )
    }
}
