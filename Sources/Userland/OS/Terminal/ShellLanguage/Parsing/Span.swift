//
//  Span.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// A stretch of the typed line, by offset and length.
///
/// Nothing is copied out of the line buffer, here or anywhere below: the parse
/// hands back where things are, and the caller reads them in place. That is not
/// only about allocation, it is what lets an error point at a column.
public struct Span {
    public let start: Int
    public let count: Int

    public init(
          start: Int,
          count: Int
    ) {
        self.start = start
        self.count = count
    }


    /// Whether this is a stretch of a line `lineCount` bytes long.
    ///
    /// The one thing that has to be asked before `line + start`, and it was
    /// asked nowhere: a span is two integers that do not carry the buffer they
    /// are about, so nothing in the type stops one from being used against the
    /// wrong line, or against a line that has since been read over.
    ///
    /// The last clause is a subtraction and not `start + count <= lineCount` on
    /// purpose. That sum overflows for a large enough pair, and in Swift an
    /// overflow is a trap: the bounds check would be the thing that killed the
    /// shell. `start <= lineCount` has already been established here, and both
    /// are at least zero, so there is nothing left to overflow.
    public func isInside(_ lineCount: Int) -> Bool {
        start >= 0
        && count >= 0
        && start <= lineCount
        && count <= lineCount - start
    }
}
