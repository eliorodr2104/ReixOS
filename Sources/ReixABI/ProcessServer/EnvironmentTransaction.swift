//
//  EnvironmentTransaction.swift
//  ReixOS
//

public enum EnvironmentTransaction {
    public static let version        : UInt32 = 1
    public static let maximumBindings: UInt32 = 16

    public static func begin(
        count: UInt32,
        nonce: UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = version
        words[1] = count
        words[2] = nonce
        return Message(
            tag  : MessageTag(EnvironmentTransactionOperation.begin, length: 3),
            words: words
        )
    }

    public static func binding(
        _ binding: EnvironmentBinding,
        index    : UInt32,
        nonce    : UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = binding.rawValue
        words[1] = index
        words[2] = nonce
        return Message(
            tag  : MessageTag(EnvironmentTransactionOperation.binding, length: 3),
            words: words
        )
    }

    public static func acknowledgement(
        index: UInt32,
        nonce: UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = index
        words[1] = nonce
        return Message(
            tag  : MessageTag(EnvironmentTransactionOperation.acknowledgement, length: 2),
            words: words
        )
    }

    public static func commit(nonce: UInt32) -> Message {
        oneWord(.commit, nonce)
    }

    public static func ready(nonce: UInt32) -> Message {
        oneWord(.ready, nonce)
    }

    public static func refused(nonce: UInt32) -> Message {
        oneWord(.refused, nonce)
    }

    private static func oneWord(
        _ operation: EnvironmentTransactionOperation,
        _ value    : UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = value
        return Message(tag: MessageTag(operation, length: 1), words: words)
    }
}
