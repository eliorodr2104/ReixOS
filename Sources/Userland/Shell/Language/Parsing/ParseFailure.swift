//
//  ParseFailure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// Why a line was refused, and where.
///
/// The column travels with the reason so the shell can point at the character
/// that broke, rather than answering "syntax error" and leaving the reader to
/// find it. A terminal with no cursor addressing can still draw a caret under
/// the right column.
public struct ParseFailure: Error, Equatable {
    public let reason: Reason
    public let column: Int

    public enum Reason: Equatable {
        case empty
        case notALine
        case expectedName
        case expectedOpenParenthesis
        case expectedCloseParenthesis
        case expectedArgument
        case unterminatedText
        case tooManyArguments
        case trailingCharacters
    }

    public var message: StaticString {
        switch reason {
            case .empty                    : "nothing to run"
            case .notALine                 : "that is not a line"
            case .expectedName             : "expected a name"
            case .expectedOpenParenthesis  : "expected '(' after the verb"
            case .expectedCloseParenthesis : "expected ')'"
            case .expectedArgument         : "expected an argument"
            case .unterminatedText         : "this text is missing its closing quote"
            case .tooManyArguments         : "too many arguments"
            case .trailingCharacters       : "unexpected characters after ')'"
        }
    }
}
