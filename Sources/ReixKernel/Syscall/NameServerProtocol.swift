//
//  NameServerProtocol.swift
//  ReixOS
//
//  Shared Name Server protocol. Lives in the Reix module so BOTH the Name
//  Server and its clients agree on the same operations and service IDs.
//

/// Well-known services the Name Server can resolve. The rawValue doubles as the
/// index into the Name Server's registry table.
public enum Services: UInt32 {
    case processServer = 0
    case fileSystem    = 1
    case terminal      = 2
}


/// Request verb: travels in the message tag label. The service id travels in
/// `words[0]` — verb-in-the-tag, object-in-the-word.
public enum NameServerOperation: UInt32, IPCLabel {
    case register = 0
    case lookup   = 1

    /// Build a request message: this verb in the tag, the service id in words[0].
    public func message(for service: Services) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = service.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}


/// Reply codes from the Name Server (carried in the tag label).
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
