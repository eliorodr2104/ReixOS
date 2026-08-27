//
//  FSListBatchResult.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// What one `listBatch` came back with.
///
/// Four facts, and the fourth is why this type exists. A listing used to answer
/// one name or nothing, and "nothing" was the end of the folder *and* a server
/// that had gone *and* a folder that could not be read. A caller could not tell
/// them apart, so it told them apart afterwards by asking a second question -
/// which answers about the moment after, not the moment in question.
public struct FSListBatchResult {

    public let status: FSStatus

    /// How many entries were written. Zero is not the end: see `eof`.
    public let count: Int

    /// Where to carry on from. Meaningless once `eof` is set.
    public let next: UInt32

    /// Whether the folder ends here.
    ///
    /// The end of a folder is a fact the server knows and now says. It is not
    /// `count == 0` and it is not a status: a batch can be full *and* be the last
    /// one, and a batch can be empty because the disk stopped answering.
    public let eof: Bool

    public init(status: FSStatus, count: Int, next: UInt32, eof: Bool) {
        self.status = status
        self.count  = count
        self.next   = next
        self.eof    = eof
    }


    /// What a caller does after one batch.
    ///
    /// Every case carries the entries that came with it, which is the whole
    /// reason this is a step and not three conditions at each call site. Spelled
    /// out by hand it was spelled out differently in each place: one caller
    /// stopped on a failure before showing what the batch had already found, and
    /// another treated an empty batch as the end of the folder. Here a caller
    /// cannot reach the verdict without being handed the names.
    public enum Step {

        /// Show these, then ask again from `next`.
        case more(Int)

        /// Show these. The folder ends here.
        case end(Int)

        /// Show these, then say why the listing stopped.
        case stopped(Int, FSStatus)
    }

    /// The status is judged before the end flag, so nothing a server sets can
    /// end a caller's walk quietly.
    public var step: Step {
        guard status == .ok else { return .stopped(count, status) }
        return eof ? .end(count) : .more(count)
    }
}
