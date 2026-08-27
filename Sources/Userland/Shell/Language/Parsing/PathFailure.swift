//
//  PathFailure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

public enum PathFailure: Error {
    /// Nothing between two separators, or nothing at all.
    case emptySegment

    /// A single colon. There is no such separator: crossing is `::`.
    case loneColon

    /// More containers or folders than a path may name.
    case tooDeep

    /// The span is not a stretch of the line it was handed with.
    ///
    /// Not a syntax error and not the typist's fault: it means the caller and
    /// the parser disagree about which line is being read, which is a shell
    /// that has lost its place rather than a path that is written wrong.
    case notALine
}
