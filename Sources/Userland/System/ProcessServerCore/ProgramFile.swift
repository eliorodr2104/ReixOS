//
//  ProgramFile.swift
//  ReixOS
//

import ReixABI

/// A program file a load reads from, and the claim that keeps it still while it
/// does.
///
/// `size` is the size under the claim. Whatever `open` said before it is a size
/// of a file somebody could still have been writing.
public protocol ProgramFile: ELFByteSource {

    /// Claims the file and learns its size under the claim.
    ///
    /// `.ok` when the claim is held. Otherwise why not: `.busy` when somebody
    /// else holds one, `.notFound` when the file is gone, `.unavailable` when
    /// the file system could not be asked. Nothing is held after a refusal.
    mutating func claim() -> ProcessServerStatus

    /// Lets go of the claim `claim` took.
    mutating func release()
}


extension ProcessServerStatus {

    /// What a launch answers when the file system answered `status` to its claim.
    ///
    /// `.notFound` is a file removed between `open` and the claim, whose handle
    /// now names nothing. Anything else that is not a yes is a file system this
    /// launch could not use, `readOnly` included: a view that cannot claim.
    public init(claiming status: FSStatus) {
        switch status {
            case .ok: self = .ok
            case .busy: self = .busy
            case .notFound: self = .notFound
            default: self = .unavailable
        }
    }
}
