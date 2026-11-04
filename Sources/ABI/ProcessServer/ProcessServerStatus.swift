//
//  ProcessServerStatus.swift
//  ReixOS
//

public enum ProcessServerStatus: UInt32, Error {
    case ok = 0
    case badRequest
    case notFound
    case malformedELF
    case capacity
    case taskFailure
    case bootstrapFailure
    case unavailable

    /// Refused for now and worth asking again: somebody else holds a claim on the
    /// program file, or this requester already has a launch in flight.
    case busy

    /// The launch was not finished by the deadline it was given when accepted.
    /// Everything it held has been given back, or, for a job still stopping, is
    /// supervised until it exits, before this answer is sent.
    case timedOut

    public var response: Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = rawValue
        return Message(
            tag  : MessageTag(ProcessServerOperation.launch, length: 1),
            words: words
        )
    }
}
