//
//  BootMessage.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

/// What a service says to the process that started it.
///
/// One vocabulary for that channel, and it has to be one: labels are numbers,
/// and two enums on the same endpoint is two sets of numbers meaning different
/// things at the same address. Sending a `FileOperation` here once cost an
/// afternoon - its `answer` carries the label `status`, which is 1, and so did
/// the second case below.
public enum BootMessage: UInt32, IPCLabel {

    /// Here I am, and here is what I have to hand over. The grant is the point;
    /// the words are not read.
    case announce

    /// The disk this service was handed is empty, and it is asking rather than
    /// filling it in.
    ///
    /// A blank disk is the one a file system could safely write over, and it
    /// still does not, because "safely" is not the same as "its decision". A
    /// disk that was anything other than empty is never asked about at all: it
    /// is refused where it was read, unwritten.
    case blankDisk

    /// Yes, to whatever was asked.
    case allowed

    /// No. The default for a question nobody answered, and for an answer that
    /// never arrived, because both mean the same thing: nobody said to.
    case refused

    public var message: Message {
        Message(
            tag  : MessageTag(self, length: 0),
            words: InlineArray<4, UInt32>(repeating: 0)
        )
    }
}
