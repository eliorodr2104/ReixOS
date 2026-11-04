//
//  ShellCatalog.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Where the documentation of everything reachable from this shell is merged.
///
/// Nothing is written here: providers hand over what they answer to, and the
/// catalog only records who said what. Resolution, dispatch, help, highlighting
/// and completion then read one table, so a command cannot be offered by one
/// and unknown to another.
public struct ShellCatalog {
    public static let commandCapacity   = 32
    public static let namespaceCapacity = 8

    /// One provider, as an index rather than as a copy of what it says.
    ///
    /// The catalog used to hold every descriptor it was handed, which made it
    /// thousands of bytes and made everything that carried one thousands of
    /// bytes heavier. A provider already knows its own commands; this
    /// remembers who to ask and where its commands begin.
    private struct Entry {
        let receiver: ShellNamespaceDescriptor
        let count   : Int
        let first   : Int
        let command : (Int) -> ShellCommandDescriptor?
    }

    private var providers = InlineArray<8, Entry?>(repeating: nil)

    public private(set) var count          = 0
    public private(set) var namespaceCount = 0

    public init() {}

    /// Takes in one provider's documentation, whole or not at all.
    ///
    /// A namespace claimed twice, or more commands than there is room for, is
    /// refused: a half-merged provider would offer commands nothing can name.
    public mutating func merge<Provider: ShellCommandProvider>(_ provider: Provider.Type) -> Bool {
        let receiver = Provider.namespace
        guard namespaceCount < providers.count,
              Provider.commandCount >= 0,
              count + Provider.commandCount <= Self.commandCapacity,
              namespaceIndex(named: receiver.name) == nil
        else { return false }

        // Every command is read once here, so a provider that files one under
        // somebody else's receiver is refused before anything is recorded.
        for index in 0..<Provider.commandCount {
            guard let descriptor = Provider.command(at: index),
                  same(descriptor.signature.namespace, receiver.name)
            else { return false }
        }

        providers[namespaceCount] = Entry(
            receiver: receiver,
            count   : Provider.commandCount,
            first   : count,
            command : Provider.command(at:)
        )
        namespaceCount += 1
        count += Provider.commandCount
        return true
    }

    public func command(at index: Int) -> ShellCommandDescriptor? {
        guard index >= 0, index < count else { return nil }
        for position in 0..<namespaceCount {
            guard let entry = providers[position] else { continue }
            if index >= entry.first, index < entry.first + entry.count {
                return entry.command(index - entry.first)
            }
        }
        return nil
    }

    /// The parameter whose value is being written in this context.
    ///
    /// Analyzer, static completion and a module's dynamic completion all ask
    /// this one rule, so labels and positional arguments cannot drift apart.
    public func parameter(for context: ShellCompletionContext) -> TypedShellParameter? {
        guard let descriptor = command(at: context.command) else { return nil }
        let position = descriptor.signature.parameterCount == 1 ? 0 : context.argument
        guard position >= 0, position < descriptor.signature.parameterCount else { return nil }
        return descriptor.signature.parameters[position]
    }

    /// The receiver that answers the command at `index`.
    public func receiver(ofCommandAt index: Int) -> ShellNamespaceDescriptor? {
        guard index >= 0, index < count else { return nil }
        for position in 0..<namespaceCount {
            guard let entry = providers[position] else { continue }
            if index >= entry.first, index < entry.first + entry.count { return entry.receiver }
        }
        return nil
    }

    public func namespace(at index: Int) -> ShellNamespaceDescriptor? {
        guard index >= 0, index < namespaceCount else { return nil }
        return providers[index]?.receiver
    }

    /// The receivers, as the parser needs them: names only, in merge order.
    public func namespaceSet() -> ShellNamespaceSet {
        var set = ShellNamespaceSet()
        for index in 0..<namespaceCount {
            guard let entry = providers[index], set.insert(entry.receiver.name) else { break }
        }
        return set
    }

    public func namespaceIndex(named name: StaticString) -> Int? {
        for index in 0..<namespaceCount {
            guard let entry = providers[index] else { continue }
            if same(entry.receiver.name, name) { return index }
        }
        return nil
    }

    /// Lends the signature table resolution runs against. An index into it is
    /// an index into this catalog, which is how dispatch finds the provider.
    public func withSignatures<Result>(
        _ body: (UnsafeBufferPointer<TypedShellSignature?>) -> Result
    ) -> Result {
        var table = InlineArray<32, TypedShellSignature?>(repeating: nil)
        for index in 0..<count { table[index] = command(at: index)?.signature }
        return table.span.withUnsafeBufferPointer { all in
            body(UnsafeBufferPointer(start: all.baseAddress!, count: count))
        }
    }

    private func same(
        _ left : StaticString,
        _ right: StaticString
    ) -> Bool {
        guard left.utf8CodeUnitCount == right.utf8CodeUnitCount else { return false }
        for index in 0..<left.utf8CodeUnitCount where left.utf8Start[index] != right.utf8Start[index] {
            return false
        }
        return true
    }

    // MARK: The language itself

    /// Members and methods belong to no provider: they are what the evaluator
    /// answers on a value, whoever produced it.
    ///
    /// They belong to a *type*, though. A list of entries answers `count` and
    /// `filter`; one entry answers `name` and `isFolder`; and neither answers
    /// the other's, which is what the editor was getting wrong.
    public static func memberCount(of schema: ShellTypeSchema) -> Int {
        switch schema.shape {
            case .nothing: return 0
            case .list: return 4
            case .one:
                switch schema.element {
                    case .entry: return 5
                    case .process: return 2
                    case .text: return 2
                    case .named: return 1
                    default: return 0
                }
        }
    }

    public static func member(
        of schema: ShellTypeSchema,
        at index : Int
    ) -> ShellMemberDescriptor? {
        guard index >= 0, index < memberCount(of: schema) else { return nil }
        if schema.isList {
            switch index {
                case 0: return ShellMemberDescriptor("count", type: .number, summary: "how many there are")
                case 1: return ShellMemberDescriptor("isEmpty", type: .boolean, summary: "true when there are none")
                case 2: return ShellMemberDescriptor("first", type: schema.elementType, summary: "the one at the front")
                default: return ShellMemberDescriptor("last", type: schema.elementType, summary: "the one at the back")
            }
        }
        switch schema.element {
            case .entry:
                switch index {
                    case 0: return ShellMemberDescriptor("name", type: .text, summary: "what it is called")
                    case 1: return ShellMemberDescriptor("path", type: .text, summary: "the same name, spelled in full")
                    case 2: return ShellMemberDescriptor("isFolder", type: .boolean, summary: "true for a folder or a container")
                    case 3: return ShellMemberDescriptor("isContainer", type: .boolean, summary: "true for a container, which is a root of its own")
                    default: return ShellMemberDescriptor("isFile", type: .boolean, summary: "true for a file")
                }
            case .process:
                return index == 0
                    ? ShellMemberDescriptor("name", type: .text, summary: "the program this process runs")
                    : ShellMemberDescriptor("id", type: .number, summary: "the number the kernel knows it by")
            case .text:
                return index == 0
                    ? ShellMemberDescriptor("isEmpty", type: .boolean, summary: "true when it says nothing")
                    : ShellMemberDescriptor("count", type: .number, summary: "how many bytes it is")
            case .named:
                return ShellMemberDescriptor("name", type: .text, summary: "what a closure called it")
            default:
                return nil
        }
    }

    public static func methodCount(of schema: ShellTypeSchema) -> Int {
        switch schema.shape {
            case .nothing: return 0
            case .list: return 9
            case .one:
                switch schema.element {
                    case .text: return 8
                    case .nothing: return 0
                    default: return 1
                }
        }
    }

    public static func method(
        of schema: ShellTypeSchema,
        at index : Int
    ) -> ShellMethodDescriptor? {
        guard index >= 0, index < methodCount(of: schema) else { return nil }
        if schema.isList {
            switch index {
                case 0:
                    return ShellMethodDescriptor("filter", argument: .closure, result: .sameAsReceiver,
                                                 closureResult: .boolean,
                                                 signature: "((Element) -> Bool) -> [Element]",
                                                 summary: "keep the ones the closure says true to")
                case 1:
                    return ShellMethodDescriptor("map", argument: .closure, result: .listOfClosureAnswer,
                                                 signature: "((Element) -> T) -> [T]",
                                                 summary: "one answer per element")
                case 2:
                    return ShellMethodDescriptor("compactMap", argument: .closure, result: .listOfClosureAnswer,
                                                 signature: "((Element) -> T?) -> [T]",
                                                 summary: "map, dropping the empty answers")
                case 3:
                    return ShellMethodDescriptor("flatMap", argument: .closure, result: .closureAnswer,
                                                 closureResult: .sequence,
                                                 signature: "((Element) -> [T]) -> [T]",
                                                 summary: "map to lists and join them")
                case 4:
                    return ShellMethodDescriptor("sorted", argument: .closure, result: .sameAsReceiver,
                                                 closureResult: .boolean,
                                                 closureParameters: 2,
                                                 signature: "((Element, Element) -> Bool) -> [Element]",
                                                 summary: "order by a closure over $0 and $1")
                case 5:
                    return ShellMethodDescriptor("reversed", argument: .none, result: .sameAsReceiver,
                                                 signature: "() -> [Element]",
                                                 summary: "the same ones, back to front")
                case 6:
                    return ShellMethodDescriptor("contains", argument: .closure, result: .fixed(.boolean),
                                                 closureResult: .boolean,
                                                 signature: "((Element) -> Bool) -> Bool",
                                                 summary: "true when the closure says so of any of them")
                case 7:
                    return ShellMethodDescriptor("allSatisfy", argument: .closure, result: .fixed(.boolean),
                                                 closureResult: .boolean,
                                                 signature: "((Element) -> Bool) -> Bool",
                                                 summary: "true when the closure says so of every one")
                default:
                    return ShellMethodDescriptor("toString", argument: .none, result: .fixed(.text),
                                                 signature: "() -> String",
                                                 summary: "the value, written out")
            }
        }
        guard schema.element == .text else {
            return ShellMethodDescriptor("toString", argument: .none, result: .fixed(.text),
                                         signature: "() -> String",
                                         summary: "the value, written out")
        }
        switch index {
            case 0:
                return ShellMethodDescriptor("contains", argument: .text, result: .fixed(.boolean),
                                             signature: "(String) -> Bool",
                                             summary: "true when the string holds the other")
            case 1:
                return ShellMethodDescriptor("hasPrefix", argument: .text, result: .fixed(.boolean),
                                             signature: "(String) -> Bool",
                                             summary: "true when it starts with the other")
            case 2:
                return ShellMethodDescriptor("hasSuffix", argument: .text, result: .fixed(.boolean),
                                             signature: "(String) -> Bool",
                                             summary: "true when it ends with the other")
            case 3:
                return ShellMethodDescriptor("appending", argument: .text, result: .fixed(.text),
                                             signature: "(String) -> String",
                                             summary: "return a string with the other appended")
            case 4:
                return ShellMethodDescriptor("lowercased", argument: .none, result: .fixed(.text),
                                             signature: "() -> String",
                                             summary: "lowercase ASCII letters, preserving other UTF-8")
            case 5:
                return ShellMethodDescriptor("uppercased", argument: .none, result: .fixed(.text),
                                             signature: "() -> String",
                                             summary: "uppercase ASCII letters, preserving other UTF-8")
            case 6:
                return ShellMethodDescriptor("trimmed", argument: .none, result: .fixed(.text),
                                             signature: "() -> String",
                                             summary: "remove ASCII whitespace at both ends")
            default:
                return ShellMethodDescriptor("toString", argument: .none, result: .fixed(.text),
                                             signature: "() -> String",
                                             summary: "the value, written out")
        }
    }
}
