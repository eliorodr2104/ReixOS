//
//  ShellCompletionEngine.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// What fits where the cursor is, taken from what the line was read against.
///
/// The analysis already decided what kind of thing belongs here; this only
/// goes and gets them. Nothing is searched twice and nothing is offered that
/// the language would refuse: a receiver's verbs after its dot, a command's
/// labels inside its parentheses, a value's members after its dot.
public enum ShellCompletionEngine {

    public static func complete(
        for snapshot: ShellAnalysisSnapshot,
        source      : UnsafePointer<UInt8>,
        count       : Int,
        catalog     : borrowing ShellCatalog
    ) -> ShellCompletionSet {
        var set     = ShellCompletionSet()
        let context = snapshot.context
        let prefix  = context.prefix
        guard prefix.start >= 0, prefix.start + prefix.count <= count else { return set }

        func offer(_ candidate: ShellCompletion?) {
            guard let candidate else { return }
            guard candidate.withName({ bytes, length in
                matches(source, prefix, bytes, length)
            }) else { return }
            set.insert(candidate)
        }

        func offerBindings() {
            for index in 0..<snapshot.bindingCount {
                guard let binding = snapshot.binding(at: index),
                      Int(binding.start) + Int(binding.count) <= count
                else { continue }
                offer(ShellCompletion(
                    kind   : .variable,
                    bytes  : source.advanced(by: Int(binding.start)),
                    count  : Int(binding.count),
                    detail : "a name this line gave a value",
                    summary: "bound by let",
                    rank   : 1
                ))
            }
        }

        switch context.subject {
            case .none:
                return set

            case .receiverOrCommand:
                for index in 0..<catalog.namespaceCount {
                    guard let receiver = catalog.namespace(at: index) else { continue }
                    offer(ShellCompletion(
                        kind   : .namespace,
                        name   : receiver.name,
                        suffix : ".",
                        detail : "receiver",
                        summary: receiver.summary,
                        rank   : 0
                    ))
                }
                for index in 0..<catalog.count {
                    guard let descriptor = catalog.command(at: index),
                          !descriptor.signature.namespaceRequired
                    else { continue }
                    offer(command(descriptor, rank: 2))
                }
                offer(ShellCompletion(
                    kind   : .keyword,
                    name   : "let",
                    suffix : " ",
                    detail : "keyword",
                    summary: "give what follows a name",
                    rank   : 1
                ))
                offerBindings()

            case .command:
                guard let receiver = catalog.namespace(at: context.receiver) else { return set }
                for index in 0..<catalog.count {
                    guard let descriptor = catalog.command(at: index),
                          let owner = catalog.receiver(ofCommandAt: index),
                          same(owner.name, receiver.name)
                    else { continue }
                    offer(command(descriptor, rank: 1))
                }

            case .label:
                guard let descriptor = catalog.command(at: context.command) else { return set }
                for position in 0..<descriptor.signature.parameterCount {
                    guard let parameter = descriptor.signature.parameters[position] else { continue }
                    offer(ShellCompletion(
                        kind   : .label,
                        name   : parameter.label,
                        suffix : ": ",
                        detail : typeName(parameter.type),
                        summary: parameter.required ? "required" : "optional"
                    ))
                }

            case .member:
                for index in 0..<ShellCatalog.memberCount(of: context.schema) {
                    guard let member = ShellCatalog.member(of: context.schema, at: index) else { continue }
                    offer(ShellCompletion(
                        kind   : .member,
                        name   : member.name,
                        detail : member.type.name,
                        summary: member.summary,
                        rank   : 0
                    ))
                }
                for index in 0..<ShellCatalog.methodCount(of: context.schema) {
                    guard let method = ShellCatalog.method(of: context.schema, at: index) else { continue }
                    offer(ShellCompletion(
                        kind   : .method,
                        name   : method.name,
                        detail : method.result.name,
                        summary: method.summary,
                        rank   : 1
                    ))
                }

            case .value:
                offerBindings()
        }
        return set
    }

    private static func command(
        _ descriptor: ShellCommandDescriptor,
          rank      : UInt8
    ) -> ShellCompletion? {
        ShellCompletion(
            kind     : .command,
            name     : descriptor.signature.name,
            // What it answers with, spelled the way the language spells it:
            // `[File]` and not the word `sequence`.
            detail   : descriptor.schema.isEmptyType
                ? typeName(descriptor.signature.result)
                : descriptor.schema.name,
            summary  : descriptor.summary,
            sensitive: descriptor.sensitive,
            rank     : rank
        )
    }

    /// The shape of a value, for the column beside a name.
    public static func typeName(_ type: ShellValueType) -> StaticString {
        switch type {
            case .void: return "Void"
            case .boolean: return "Bool"
            case .number: return "Number"
            case .text: return "Text"
            case .record: return "Record"
            case .sequence: return "Sequence"
            case .any: return "Any"
        }
    }

    /// Whether a candidate begins with what has been typed. Nothing clever:
    /// a prefix, byte for byte, so what is offered is what would have been
    /// written anyway.
    private static func matches(
        _ source: UnsafePointer<UInt8>,
        _ prefix: Span,
        _ name  : UnsafePointer<UInt8>,
        _ length: Int
    ) -> Bool {
        guard prefix.count <= length else { return false }
        for index in 0..<prefix.count where source[prefix.start + index] != name[index] {
            return false
        }
        return true
    }

    private static func same(
        _ left : StaticString,
        _ right: StaticString
    ) -> Bool {
        guard left.utf8CodeUnitCount == right.utf8CodeUnitCount else { return false }
        for index in 0..<left.utf8CodeUnitCount where left.utf8Start[index] != right.utf8Start[index] {
            return false
        }
        return true
    }
}
