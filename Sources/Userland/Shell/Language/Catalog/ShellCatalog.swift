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
    public static func memberCount(of schema: ShellTypeSchema) -> Int {
        switch schema {
            case .none: return 0
            case .file: return 4
            case .process: return 1
        }
    }

    public static func member(
        of schema: ShellTypeSchema,
        at index : Int
    ) -> ShellMemberDescriptor? {
        guard index >= 0, index < memberCount(of: schema) else { return nil }
        switch schema {
            case .none: return nil
            case .file:
                switch index {
                    case 0: return ShellMemberDescriptor("name", type: .text, summary: "what it is called")
                    case 1: return ShellMemberDescriptor("path", type: .text, summary: "the same name, spelled in full")
                    case 2: return ShellMemberDescriptor("isFolder", type: .boolean, summary: "true for a folder or a container")
                    default: return ShellMemberDescriptor("isFile", type: .boolean, summary: "true for a file")
                }
            case .process:
                return ShellMemberDescriptor("name", type: .text, summary: "the program this process runs")
        }
    }

    public static let methodCount = 7

    public static func method(at index: Int) -> ShellMethodDescriptor? {
        switch index {
            case 0: return ShellMethodDescriptor("filter", receiver: .sequence, argument: .closure, result: .sequence, summary: "keep the ones the closure says true to")
            case 1: return ShellMethodDescriptor("map", receiver: .sequence, argument: .closure, result: .sequence, summary: "one answer per element")
            case 2: return ShellMethodDescriptor("compactMap", receiver: .sequence, argument: .closure, result: .sequence, summary: "map, dropping the empty answers")
            case 3: return ShellMethodDescriptor("flatMap", receiver: .sequence, argument: .closure, result: .sequence, summary: "map to sequences and join them")
            case 4: return ShellMethodDescriptor("sorted", receiver: .sequence, argument: .closure, result: .sequence, summary: "order by a closure over $0 and $1")
            case 5: return ShellMethodDescriptor("contains", receiver: .text, argument: .text, result: .boolean, summary: "true when the text holds the other")
            case 6: return ShellMethodDescriptor("toString", receiver: .any, argument: .none, result: .text, summary: "the value, written out")
            default: return nil
        }
    }
}
