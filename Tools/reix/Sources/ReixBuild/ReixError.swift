//
//  ReixError.swift
//  ReixOS
//

import Foundation

/// A tool exited non-zero, or refused its input. Carries the tool's own output
/// verbatim: it is what the reader has to read, and reflowing it loses it.
public enum ReixError: Error, CustomStringConvertible {
    case tool(String)

    public var description: String {
        switch self { case .tool(let message): return message }
    }
}
