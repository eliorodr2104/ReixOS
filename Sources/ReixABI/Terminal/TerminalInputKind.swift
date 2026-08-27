//
//  TerminalInputKind.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

/// Keystrokes after the hardware decoder and before the shell's line editor.
/// The terminal owns escape-sequence decoding; the shell owns editing and
/// history. Source text is the only variable payload, and executable syntax is
/// never a wire value.
public enum TerminalInputKind: UInt16, Equatable {
    case insert = 1
    case left = 2
    case right = 3
    case up = 4
    case down = 5
    case home = 6
    case end = 7
    case backspace = 8
    case delete = 9
    case enter = 10
    case cancel = 11
    case eof = 12
    case historyPrevious = 13
    case historyNext = 14
    case resize = 15
    case ignored = 16
}
