//
//  ProcessServerStatus.swift
//  ReixOS
//

public enum ProcessServerStatus: UInt32 {
    case ok = 0
    case badRequest
    case notFound
    case malformedELF
    case capacity
    case taskFailure
    case bootstrapFailure
    case unavailable

    /// Somebody else holds a claim on the program file, a writer part way
    /// through changing it. Refused rather than loaded, and worth asking again.
    case busy

    public var response: Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = rawValue
        return Message(
            tag  : MessageTag(ProcessServerOperation.launch, length: 1),
            words: words
        )
    }
}
