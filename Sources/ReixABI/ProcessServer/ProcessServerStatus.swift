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

    public var response: Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = rawValue
        return Message(
            tag  : MessageTag(ProcessServerOperation.launch, length: 1),
            words: words
        )
    }
}
