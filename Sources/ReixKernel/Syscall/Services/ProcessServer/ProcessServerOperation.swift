//
//  Operation.swift
//  ReixOS
//
//  Process Server request verbs (carried in the message tag label).
//

public enum ProcessServerOperation: UInt32, IPCLabel {
    case spawn = 0

    /// Build a request: this verb in the tag, the program id in words[0].
    public func message(for program: ProgramID) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = program.rawValue
        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}
