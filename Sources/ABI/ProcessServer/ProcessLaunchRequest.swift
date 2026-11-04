//
//  ProcessLaunchRequest.swift
//  ReixOS
//

public enum ProcessLaunchRequest {
    public static let maximumNameBytes = 12

    public static func message(
        name  : UnsafePointer<UInt8>,
        length: Int
    ) -> Message? {
        guard length > 0, length <= maximumNameBytes else { return nil }

        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = UInt32(length)

        for index in 0..<length {
            let word  = 1 + index / 4
            let shift = UInt32((index % 4) * 8)
            words[word] |= UInt32(name[index]) << shift
        }

        return Message(
            tag  : MessageTag(ProcessServerOperation.launch, length: 4),
            words: words
        )
    }

    public static func name(
        from message: Message
    ) -> (bytes: InlineArray<12, UInt8>, length: Int)? {
        guard message.tag.label == ProcessServerOperation.launch.rawValue,
              message.tag.length == 4
        else { return nil }

        let length = Int(message.words[0])
        guard length > 0, length <= maximumNameBytes else { return nil }

        var bytes = InlineArray<12, UInt8>(repeating: 0)
        for index in 0..<length {
            let word  = 1 + index / 4
            let shift = UInt32((index % 4) * 8)
            bytes[index] = UInt8(truncatingIfNeeded: message.words[word] >> shift)
        }

        return (bytes, length)
    }
}
