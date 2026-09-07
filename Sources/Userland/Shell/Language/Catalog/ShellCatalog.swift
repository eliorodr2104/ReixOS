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

    private var entries    = InlineArray<32, ShellCommandDescriptor?>(repeating: nil)
    private var owners     = InlineArray<32, UInt8>(repeating: 0)
    private var receivers  = InlineArray<8, ShellNamespaceDescriptor?>(repeating: nil)

    public private(set) var count          = 0
    public private(set) var namespaceCount = 0

    public init() {}

    /// Takes in one provider's documentation, whole or not at all.
    ///
    /// A namespace claimed twice, or more commands than there is room for, is
    /// refused: a half-merged provider would offer commands nothing can name.
    public mutating func merge<Provider: ShellCommandProvider>(_ provider: Provider.Type) -> Bool {
        let receiver = Provider.namespace
        guard namespaceCount < receivers.count,
              Provider.commandCount >= 0,
              count + Provider.commandCount <= entries.count,
              namespaceIndex(named: receiver.name) == nil
        else { return false }

        let owner = namespaceCount
        for index in 0..<Provider.commandCount {
            guard let descriptor = Provider.command(at: index),
                  same(descriptor.signature.namespace, receiver.name)
            else { return false }
            entries[count + index] = descriptor
            owners[count + index] = UInt8(owner)
        }
        receivers[owner] = receiver
        namespaceCount += 1
        count += Provider.commandCount
        return true
    }

    public func command(at index: Int) -> ShellCommandDescriptor? {
        guard index >= 0, index < count else { return nil }
        return entries[index]
    }

    /// The receiver that answers the command at `index`.
    public func receiver(ofCommandAt index: Int) -> ShellNamespaceDescriptor? {
        guard index >= 0, index < count else { return nil }
        return receivers[Int(owners[index])]
    }

    public func namespace(at index: Int) -> ShellNamespaceDescriptor? {
        guard index >= 0, index < namespaceCount else { return nil }
        return receivers[index]
    }

    public func namespaceIndex(named name: StaticString) -> Int? {
        for index in 0..<namespaceCount {
            guard let receiver = receivers[index] else { continue }
            if same(receiver.name, name) { return index }
        }
        return nil
    }

    /// Lends the signature table resolution runs against. An index into it is
    /// an index into this catalog, which is how dispatch finds the provider.
    public func withSignatures<Result>(
        _ body: (UnsafeBufferPointer<TypedShellSignature?>) -> Result
    ) -> Result {
        var table = InlineArray<32, TypedShellSignature?>(repeating: nil)
        for index in 0..<count { table[index] = entries[index]?.signature }
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
