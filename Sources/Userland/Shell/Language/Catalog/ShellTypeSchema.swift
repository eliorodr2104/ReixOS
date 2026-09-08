//
//  ShellTypeSchema.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What a value is, as far as this language can say it.
///
/// `sequence` was never a type: `fileSystem.list()` answers with a list of
/// files, and a list is not what its elements are. Saying so is what lets the
/// editor offer `count` on the list and `isFolder` on what is in it, rather
/// than offering both on both.
public struct ShellTypeSchema: Equatable {

    /// What one of them is.
    public enum Element: UInt8, Equatable {
        case nothing

        /// One thing a container holds. Deliberately not `File`: a folder and
        /// a container are entries too, and somebody reading `[File]` would
        /// not expect a folder in it.
        case entry
        case process
        case text
        case number
        case boolean

        /// What a closure answered when it did not answer with an entry: the
        /// evaluator keeps it as an object with a name, and that is all it
        /// promises about it.
        case named
    }

    /// How many of them there are.
    public enum Shape: UInt8, Equatable {
        case nothing
        case one
        case list
    }

    public let shape  : Shape
    public let element: Element

    public init(
        shape  : Shape,
        element: Element
    ) {
        self.shape = shape
        self.element = element
    }

    public static let none      = ShellTypeSchema(shape: .nothing, element: .nothing)
    public static let entry     = ShellTypeSchema(shape: .one, element: .entry)
    public static let named     = ShellTypeSchema(shape: .one, element: .named)
    public static let process   = ShellTypeSchema(shape: .one, element: .process)
    public static let text      = ShellTypeSchema(shape: .one, element: .text)
    public static let number    = ShellTypeSchema(shape: .one, element: .number)
    public static let boolean   = ShellTypeSchema(shape: .one, element: .boolean)
    public static let entries   = ShellTypeSchema(shape: .list, element: .entry)
    public static let processes = ShellTypeSchema(shape: .list, element: .process)
    public static let texts     = ShellTypeSchema(shape: .list, element: .text)

    public var isList : Bool { shape == .list }
    public var isEmptyType: Bool { shape == .nothing }

    /// What one element of a list is, which is what `$0` stands for inside a
    /// closure over it.
    public var elementType: ShellTypeSchema {
        shape == .list ? ShellTypeSchema(shape: .one, element: element) : .none
    }

    /// A list of these, which is what filtering or mapping answers with.
    public var listType: ShellTypeSchema {
        ShellTypeSchema(shape: .list, element: element)
    }

    /// How it is written, so a panel says `[File]` where the language would.
    public var name: StaticString {
        switch shape {
            case .nothing: return "Void"
            case .one:
                switch element {
                    case .nothing: return "Void"
                    case .entry: return "Entry"
                    case .named: return "Named"
                    case .process: return "Process"
                    case .text: return "Text"
                    case .number: return "Number"
                    case .boolean: return "Bool"
                }
            case .list:
                switch element {
                    case .nothing: return "[]"
                    case .entry: return "[Entry]"
                    case .named: return "[Named]"
                    case .process: return "[Process]"
                    case .text: return "[Text]"
                    case .number: return "[Number]"
                    case .boolean: return "[Bool]"
                }
        }
    }
}
