//
//  ShellSession.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

/// Everything a module is allowed to know and change about the shell.
///
/// A module is handed this and nothing else. That is the point of it being a
/// type rather than a pile of globals: what a module can reach is written down
/// in one place, and when the shell becomes a server answering programs rather
/// than a loop reading a keyboard, this is the thing that will be handed to
/// them instead of to functions in the same binary.
public struct ShellSession {

    /// The capabilities this shell was started with. A module that wants to do
    /// something asks here for the authority to do it, and gets nothing if it
    /// was not given any.
    public let environment: Environment

    /// The line being carried out, and how much of it there is.
    ///
    /// The pointer is private and the length is not. A `Span` is two integers
    /// that do not carry the buffer they are about, so handing a module the
    /// pointer is handing it the arithmetic - and the arithmetic was the whole
    /// hazard: `line + span.start` was written wherever a name was wanted, and
    /// each one of those read wherever the span said to. Everything a module
    /// needs goes through the accessors below, and every accessor asks
    /// `isInside` first.
    private let buffer: UnsafePointer<UInt8>

    /// How many bytes of the line were typed. A span is measured against this.
    public let lineCount: Int

    /// Where the shell is standing: a container, and a folder inside it.
    ///
    /// Two numbers rather than a written path, because a path would have to be
    /// resolved again on every command and hoped to still mean the same thing.
    /// A module may move the shell by writing here, and that is the shell's own
    /// data that a module manipulates.
    public var container: UInt32 = 0
    public var folder   : UInt32 = 0

    public init(
          environment: Environment,
          line       : UnsafePointer<UInt8>,
          count      : Int
    ) {
        self.environment = environment
        self.buffer      = line
        self.lineCount   = count
    }


    /// The bytes a span covers, or nil when it is not a stretch of this line.
    private func text(_ span: Span) -> (bytes: UnsafePointer<UInt8>, count: Int)? {
        guard span.isInside(lineCount) else { return nil }

        return (buffer + span.start, span.count)
    }


    /// The bytes a span covers. A failed bounds check is data, not presentation:
    /// the module that owns the command chooses a typed failure or stops.
    public func bytes(of span: Span) -> (bytes: UnsafePointer<UInt8>, count: Int)? {
        text(span)
    }


    /// Whether a span reads exactly `word`.
    public func spells(
        _ span: Span,
        _ word: StaticString
    ) -> Bool {
        guard let found = text(span), found.count == word.utf8CodeUnitCount else {
            return false
        }

        for index in 0..<found.count where found.bytes[index] != word.utf8Start[index] {
            return false
        }

        return true
    }


    /// A written path, taken apart. Nil when the span is not this line's.
    ///
    /// The bounds check is the parser's now: it takes the length and refuses a
    /// span that is not a stretch of it, so this door cannot be the only thing
    /// standing between a stray pair of integers and a read. What is left here
    /// is retained as a typed parser failure for the module to render.
    public func path(_ span: Span) -> Result<PathParts, PathFailure>? {
        PathParser.parse(buffer, count: lineCount, span: span)
    }


    /// Prints what a span covers, and nothing when it covers nothing.
    public func echo(_ span: Span) {
        guard let found = text(span) else { return }

        printPadded(found.bytes, count: found.count, width: 0)
    }

}
