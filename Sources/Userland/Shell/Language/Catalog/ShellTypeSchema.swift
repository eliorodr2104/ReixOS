//
//  ShellTypeSchema.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// The shape behind a value, when the value type alone does not say it.
///
/// `.record` says a command answers with an object; this says which object, so
/// completion and help can name its members before anything has run.
public enum ShellTypeSchema: UInt8, Equatable {
    case none
    case file
    case process
}
