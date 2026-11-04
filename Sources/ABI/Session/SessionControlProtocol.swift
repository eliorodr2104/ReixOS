//
//  SessionControlProtocol.swift
//  ReixOS
//

/// Requests a foreground program may make of the process that supervises its
/// terminal session. The endpoint is supplied by the spawner; there is no
/// ambient session service.
public enum SessionControlOperation: UInt32, IPCLabel {
    case shutdown = 1

    public var request: Message {
        Message(
            tag  : MessageTag(self, length: 0),
            words: InlineArray<4, UInt32>(repeating: 0)
        )
    }
}

public enum SessionControlStatus: UInt32 {
    case ok          = 0
    case refused     = 1
    case unavailable = 2
    case malformed   = 3

    public var response: Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = rawValue

        return Message(
            tag  : MessageTag(SessionControlOperation.shutdown, length: 1),
            words: words
        )
    }
}
