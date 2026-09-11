//
//  ShellLexer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Reads a revision the way an editor has to: all of it, whatever state it is
/// in.
///
/// The parser answers one question, whether this is a program, and answers it
/// with a failure and a column. That is the wrong shape for somebody halfway
/// through typing a string: the quote they have not closed yet would throw
/// away the reading of everything before it. This one never refuses. A token
/// that is unfinished says so and the line around it stands, which is what
/// highlighting, completion and diagnostics all read.
///
/// It runs nothing and resolves nothing. Whether `a.txt` is one word or a
/// member of `a` is a question about the call it sits in, and the answer to
/// that comes from the catalog, later.
public enum ShellLexer {

    /// The longest revision this reads. The editor's own capacity is well
    /// inside it; a longer buffer is read up to here and marked truncated.
    public static let byteLimit = 8192

    public static func scan(
        _ source: UnsafePointer<UInt8>,
          count : Int
    ) -> ShellTokenStream {
        var stream = ShellTokenStream()
        guard count > 0 else { return stream }

        let end = min(count, byteLimit)
        if count > byteLimit { stream.markTruncated() }

        var cursor      = 0
        var parentheses = 0
        var braces      = 0
        var unbalanced  = -1
        var openQuote   = false

        func emit(
            _ kind : ShellTokenKind,
            _ state: ShellTokenState,
              from : Int,
              to   : Int
        ) {
            stream.append(
                ShellToken(
                    kind : kind,
                    state: state,
                    start: UInt16(from),
                    count: UInt16(to - from)
                )
            )
        }

        /// A word still touching the end of the input can still become longer.
        func settled(
            _ from: Int,
            _ to  : Int
        ) -> ShellTokenState {
            to == count ? .growing : .valid
        }

        while cursor < end {
            let byte = source[cursor]

            if byte == space || byte == tab {
                cursor += 1
                continue
            }

            if byte == lineFeed || byte == carriageReturn {
                let start = cursor
                cursor += 1
                if byte == carriageReturn, cursor < end, source[cursor] == lineFeed { cursor += 1 }
                emit(.newline, .valid, from: start, to: cursor)
                continue
            }

            if byte == quote {
                let start = cursor
                cursor += 1
                while cursor < end, source[cursor] != quote { cursor += 1 }
                if cursor < end {
                    cursor += 1
                    emit(.text, .valid, from: start, to: cursor)
                } else {
                    openQuote = true
                    emit(.text, .unterminated, from: start, to: cursor)
                }
                continue
            }

            if byte == dollar {
                let start = cursor
                if cursor + 1 < end, isDigit(source[cursor + 1]) {
                    cursor += 2
                    emit(.placeholder, settled(start, cursor), from: start, to: cursor)
                } else if cursor + 1 == end {
                    cursor += 1
                    emit(.placeholder, .growing, from: start, to: cursor)
                } else {
                    cursor += 1
                    emit(.unknown, .invalid, from: start, to: cursor)
                }
                continue
            }

            if isNameStart(byte) || isDigit(byte) {
                let start   = cursor
                let numeric = isDigit(byte)
                while cursor < end, isNameBody(source[cursor]) { cursor += 1 }

                // `::` and `/` belong to no expression, so a name wearing one
                // is a path and is read whole rather than in pieces.
                if isPathContinuation(source, cursor, end) {
                    while cursor < end, isPathBody(source[cursor]) { cursor += 1 }
                    emit(.path, settled(start, cursor), from: start, to: cursor)
                    continue
                }

                if numeric, allDigits(source, start, cursor) {
                    emit(.number, settled(start, cursor), from: start, to: cursor)
                } else if spells(source, start, cursor, "let") {
                    emit(.keyword, settled(start, cursor), from: start, to: cursor)
                } else {
                    emit(.name, settled(start, cursor), from: start, to: cursor)
                }
                continue
            }

            let start = cursor
            switch byte {
                case openParenthesis:
                    parentheses += 1
                    cursor += 1
                    emit(.openParenthesis, .valid, from: start, to: cursor)
                case closeParenthesis:
                    let orphanParenthesis = parentheses == 0
                    if orphanParenthesis {
                        if unbalanced < 0 { unbalanced = start }
                    } else {
                        parentheses -= 1
                    }
                    cursor += 1
                    emit(.closeParenthesis, orphanParenthesis ? .invalid : .valid, from: start, to: cursor)
                case openBrace:
                    braces += 1
                    cursor += 1
                    emit(.openBrace, .valid, from: start, to: cursor)
                case closeBrace:
                    let orphanBrace = braces == 0
                    if orphanBrace {
                        if unbalanced < 0 { unbalanced = start }
                    } else {
                        braces -= 1
                    }
                    cursor += 1
                    emit(.closeBrace, orphanBrace ? .invalid : .valid, from: start, to: cursor)
                case dot:
                    cursor += 1
                    emit(.dot, .valid, from: start, to: cursor)
                case comma:
                    cursor += 1
                    emit(.comma, .valid, from: start, to: cursor)
                case colon:
                    cursor += 1
                    emit(.colon, .valid, from: start, to: cursor)
                case equalsByte:
                    cursor += 1
                    if cursor < end, source[cursor] == equalsByte {
                        cursor += 1
                        emit(.operatorSymbol, .valid, from: start, to: cursor)
                    } else {
                        emit(.assign, .valid, from: start, to: cursor)
                    }
                case exclamation:
                    cursor += 1
                    if cursor < end, source[cursor] == equalsByte { cursor += 1 }
                    emit(.operatorSymbol, .valid, from: start, to: cursor)
                case ampersand, verticalBar:
                    cursor += 1
                    if cursor < end, source[cursor] == byte {
                        cursor += 1
                        emit(.operatorSymbol, .valid, from: start, to: cursor)
                    } else {
                        emit(.operatorSymbol, cursor == end ? .growing : .invalid, from: start, to: cursor)
                    }
                case less, greater:
                    cursor += 1
                    emit(.operatorSymbol, .valid, from: start, to: cursor)
                default:
                    cursor += 1
                    emit(.unknown, .invalid, from: start, to: cursor)
            }
        }

        var trailingOperator = false
        var trailingIndex = stream.count
        while trailingIndex > 0 {
            trailingIndex -= 1
            guard let trailing = stream.token(at: trailingIndex) else { continue }
            if trailing.kind == .newline { continue }
            trailingOperator = trailing.kind == .operatorSymbol
            break
        }
        if unbalanced >= 0 {
            stream.completeness = .invalid(column: unbalanced)
        } else if openQuote || parentheses > 0 || braces > 0 || trailingOperator {
            stream.completeness = .incomplete(indent: parentheses + braces)
        } else {
            stream.completeness = .complete
        }
        return stream
    }

    private static func isPathContinuation(
        _ source: UnsafePointer<UInt8>,
        _ cursor: Int,
        _ end   : Int
    ) -> Bool {
        guard cursor < end else { return false }
        if source[cursor] == slash { return true }
        return source[cursor] == colon && cursor + 1 < end && source[cursor + 1] == colon
    }

    private static func allDigits(
        _ source: UnsafePointer<UInt8>,
        _ start : Int,
        _ end   : Int
    ) -> Bool {
        for index in start..<end where !isDigit(source[index]) { return false }
        return true
    }

    private static func spells(
        _ source: UnsafePointer<UInt8>,
        _ start : Int,
        _ end   : Int,
        _ word  : StaticString
    ) -> Bool {
        guard end - start == word.utf8CodeUnitCount else { return false }
        for index in 0..<word.utf8CodeUnitCount where source[start + index] != word.utf8Start[index] {
            return false
        }
        return true
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (byte >= upperA && byte <= upperZ) || (byte >= lowerA && byte <= lowerZ) || byte == underscore
    }

    private static func isNameBody(_ byte: UInt8) -> Bool { isNameStart(byte) || isDigit(byte) }

    private static func isPathBody(_ byte: UInt8) -> Bool {
        isNameBody(byte) || byte == dot || byte == colon || byte == slash || byte == minus
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= nine }

    private static let tab             : UInt8 = 0x09
    private static let lineFeed        : UInt8 = 0x0A
    private static let carriageReturn  : UInt8 = 0x0D
    private static let space           : UInt8 = 0x20
    private static let exclamation     : UInt8 = 0x21
    private static let quote           : UInt8 = 0x22
    private static let dollar          : UInt8 = 0x24
    private static let ampersand       : UInt8 = 0x26
    private static let openParenthesis : UInt8 = 0x28
    private static let closeParenthesis: UInt8 = 0x29
    private static let comma           : UInt8 = 0x2C
    private static let minus           : UInt8 = 0x2D
    private static let dot             : UInt8 = 0x2E
    private static let slash           : UInt8 = 0x2F
    private static let zero            : UInt8 = 0x30
    private static let nine            : UInt8 = 0x39
    private static let colon           : UInt8 = 0x3A
    private static let less            : UInt8 = 0x3C
    private static let equalsByte      : UInt8 = 0x3D
    private static let greater         : UInt8 = 0x3E
    private static let upperA          : UInt8 = 0x41
    private static let upperZ          : UInt8 = 0x5A
    private static let underscore      : UInt8 = 0x5F
    private static let lowerA          : UInt8 = 0x61
    private static let lowerZ          : UInt8 = 0x7A
    private static let openBrace       : UInt8 = 0x7B
    private static let verticalBar     : UInt8 = 0x7C
    private static let closeBrace      : UInt8 = 0x7D
}
