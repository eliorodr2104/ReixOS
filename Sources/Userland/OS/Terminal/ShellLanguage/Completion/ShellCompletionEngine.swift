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
        let context = snapshot.context
        var set     = ShellCompletionSet(subject: context.subject)
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
                      binding.isVisible(at: prefix.start),
                      Int(binding.start) + Int(binding.count) <= count
                else { continue }
                offer(ShellCompletion(
                    kind   : .variable,
                    bytes  : source.advanced(by: Int(binding.start)),
                    count  : Int(binding.count),
                    detail : binding.type.name,
                    summary: "a typed value in this scope",
                    rank   : rank(binding.type.valueType, expected: context.expected)
                ))
            }
        }

        func offerLiterals() {
            guard context.expected == .any || context.expected == .boolean || context.expected == .void else {
                return
            }
            offer(ShellCompletion(
                kind: .keyword, name: "true", detail: "Bool",
                summary: "the Boolean value true",
                rank: rank(.boolean, expected: context.expected)
            ))
            offer(ShellCompletion(
                kind: .keyword, name: "false", detail: "Bool",
                summary: "the Boolean value false",
                rank: rank(.boolean, expected: context.expected)
            ))
            if context.expected == .any || context.expected == .void {
                offer(ShellCompletion(
                    kind: .keyword, name: "nil", detail: "Void",
                    summary: "no value",
                    rank: rank(.void, expected: context.expected)
                ))
            }
        }

        func offerOperators() {
            let explicitlyTypingOne: Bool
            if prefix.count > 0 {
                let first = source[prefix.start]
                explicitlyTypingOne = first == 0x21 || first == 0x26 || first == 0x3C
                    || first == 0x3D || first == 0x3E || first == 0x7C
            } else {
                explicitlyTypingOne = false
            }
            guard explicitlyTypingOne || !context.schema.isEmptyType else { return }

            if explicitlyTypingOne {
                offer(ShellCompletion(
                    kind: .operatorSymbol, name: "!true", detail: "Bool",
                    summary: "Boolean negation", rank: 0
                ))
                offer(ShellCompletion(
                    kind: .operatorSymbol, name: "!false", detail: "Bool",
                    summary: "Boolean negation", rank: 0
                ))
            }
            guard !context.schema.isEmptyType else { return }
            offer(ShellCompletion(
                kind: .operatorSymbol, name: "&&", suffix: " ", detail: "(Bool, Bool) -> Bool",
                summary: "short-circuiting Boolean AND", rank: context.schema == .boolean ? 0 : 2
            ))
            offer(ShellCompletion(
                kind: .operatorSymbol, name: "||", suffix: " ", detail: "(Bool, Bool) -> Bool",
                summary: "short-circuiting Boolean OR", rank: context.schema == .boolean ? 0 : 2
            ))
            offer(ShellCompletion(
                kind: .operatorSymbol, name: "==", suffix: " ", detail: "(T, T) -> Bool",
                summary: "equality", rank: 1
            ))
            offer(ShellCompletion(
                kind: .operatorSymbol, name: "!=", suffix: " ", detail: "(T, T) -> Bool",
                summary: "inequality", rank: 1
            ))
            if context.schema == .text || context.schema == .number || explicitlyTypingOne {
                offer(ShellCompletion(
                    kind: .operatorSymbol, name: "<", suffix: " ", detail: "(T, T) -> Bool",
                    summary: "less than", rank: 1
                ))
                offer(ShellCompletion(
                    kind: .operatorSymbol, name: ">", suffix: " ", detail: "(T, T) -> Bool",
                    summary: "greater than", rank: 1
                ))
            }
        }

        func resultType(of descriptor: ShellCommandDescriptor) -> ShellValueType {
            descriptor.schema.isEmptyType
                ? descriptor.signature.result
                : descriptor.schema.valueType
        }

        func fitsExpectedResult(_ descriptor: ShellCommandDescriptor) -> Bool {
            context.expected == .any || resultType(of: descriptor) == context.expected
        }

        func hasExpectedCommand(_ receiver: ShellNamespaceDescriptor) -> Bool {
            guard context.expected != .any else { return true }
            for index in 0..<catalog.count {
                guard let descriptor = catalog.command(at: index),
                      fitsExpectedResult(descriptor),
                      let owner = catalog.receiver(ofCommandAt: index),
                      same(owner.name, receiver.name)
                else { continue }
                return true
            }
            return false
        }

        switch context.subject {
            case .none:
                return set

            case .receiverOrCommand:
                for index in 0..<catalog.namespaceCount {
                    guard let receiver = catalog.namespace(at: index), hasExpectedCommand(receiver) else { continue }
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
                          !descriptor.signature.namespaceRequired,
                          fitsExpectedResult(descriptor)
                    else { continue }
                    offer(command(descriptor, rank: context.expected == .any ? 2 : 0))
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
                offerLiterals()

            case .command:
                guard let receiver = catalog.namespace(at: context.receiver) else { return set }
                for index in 0..<catalog.count {
                    guard let descriptor = catalog.command(at: index),
                          fitsExpectedResult(descriptor),
                          let owner = catalog.receiver(ofCommandAt: index),
                          same(owner.name, receiver.name)
                    else { continue }
                    offer(command(descriptor, rank: context.expected == .any ? 1 : 0))
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
                    // A method arrives with what it takes: braces for a
                    // closure, quotes for a text, and the cursor inside them.
                    offer(ShellCompletion(
                        kind   : .method,
                        name   : method.name,
                        suffix : template(for: method.argument),
                        detail : method.completionDetail(on: context.schema),
                        summary: method.summary,
                        rank   : 1,
                        caret  : caret(for: method.argument)
                    ))
                }

            case .value:
                offerBindings()
                offerLiterals()
                offerOperators()
                // The element of an enclosing closure is already known before
                // its body has an answer. Offer complete, valid expressions
                // here; waiting for somebody to type `$0.` first hid the most
                // useful part of `filter { }`, `map { }`, and `sorted { }`.
                if !context.scope.isEmptyType {
                    let implicitCount = max(1, Int(context.scopeCount))
                    for position in 0..<implicitCount {
                        let named = position == 0 ? context.scopeName : nil
                        let receiver: UnsafePointer<UInt8>
                        let receiverCount: Int
                        if let named, named.isInside(count) {
                            receiver = source.advanced(by: named.start)
                            receiverCount = named.count
                        } else {
                            let implicit: StaticString = position == 0 ? "$0" : "$1"
                            receiver = implicit.utf8Start
                            receiverCount = implicit.utf8CodeUnitCount
                        }
                        offer(ShellCompletion(
                            kind   : .variable,
                            bytes  : receiver,
                            count  : receiverCount,
                            suffix : ".",
                            detail : context.scope.name,
                            summary: "an element in this closure",
                            rank   : 1
                        ))
                        for index in 0..<ShellCatalog.memberCount(of: context.scope) {
                            guard let member = ShellCatalog.member(of: context.scope, at: index) else { continue }
                            offer(scoped(
                                receiver,
                                count: receiverCount,
                                member.name,
                                kind   : .member,
                                detail : member.type.name,
                                summary: member.summary,
                                rank   : rank(member.type.valueType, expected: context.expected)
                            ))
                        }
                        for index in 0..<ShellCatalog.methodCount(of: context.scope) {
                            guard let method = ShellCatalog.method(of: context.scope, at: index) else { continue }
                            offer(scoped(
                                receiver,
                                count: receiverCount,
                                method.name,
                                kind   : .method,
                                suffix : template(for: method.argument),
                                detail : method.completionDetail(on: context.scope),
                                summary: method.summary,
                                rank   : rank(method.resultType(on: context.scope).valueType,
                                              expected: context.expected),
                                caret  : caret(for: method.argument)
                            ))
                        }
                    }
                }
                // A parameter that names something in the catalog is offered
                // the catalog, which is what makes `help Fi` finish itself.
                if catalog.parameter(for: context)?.subject == .symbol {
                    for index in 0..<catalog.namespaceCount {
                        guard let receiver = catalog.namespace(at: index) else { continue }
                        offer(ShellCompletion(
                            kind   : .namespace,
                            name   : receiver.name,
                            detail : "receiver",
                            summary: receiver.summary,
                            rank   : 0
                        ))
                    }
                    for index in 0..<catalog.count {
                        guard let descriptor = catalog.command(at: index) else { continue }
                        offer(command(descriptor, rank: 1))
                    }
                }
        }
        return set
    }

    private static func rank(
        _ type    : ShellValueType,
          expected: ShellValueType
    ) -> UInt8 {
        expected == .any || type == expected ? 0 : 2
    }

    /// A valid member expression inside a closure, built in bounded scratch
    /// storage and copied into the candidate before that storage disappears.
    private static func scoped(
        _ receiver: UnsafePointer<UInt8>,
          count receiverCount: Int,
        _ name    : StaticString,
          kind    : ShellCompletionKind,
          suffix  : StaticString = "",
          detail  : StaticString,
          summary : StaticString,
          rank    : UInt8,
          caret   : Int = 0
    ) -> ShellCompletion? {
        let count = receiverCount + 1 + name.utf8CodeUnitCount
        guard count <= ShellCompletion.nameCapacity else { return nil }
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count) { bytes in
            var cursor = 0
            for index in 0..<receiverCount {
                bytes[cursor] = receiver[index]
                cursor += 1
            }
            bytes[cursor] = 0x2E
            cursor += 1
            for index in 0..<name.utf8CodeUnitCount {
                bytes[cursor] = name.utf8Start[index]
                cursor += 1
            }
            return ShellCompletion(
                kind   : kind,
                bytes  : bytes.baseAddress!,
                count  : count,
                suffix : suffix,
                detail : detail,
                summary: summary,
                rank   : rank,
                caret  : caret
            )
        }
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

    /// What a method's argument looks like once it is written out.
    private static func template(for argument: ShellMethodArgument) -> StaticString {
        switch argument {
            case .none: return "()"
            // Two spaces, so what is written between them ends up with one on
            // each side: `{ $0.isFolder }`.
            case .closure: return " {  }"
            case .text: return "(\"\")"
        }
    }

    /// Where the cursor belongs inside that, counted back from the end.
    private static func caret(for argument: ShellMethodArgument) -> Int {
        switch argument {
            case .none: return 0
            case .closure: return 2
            case .text: return 2
        }
    }

    /// The shape of a value, for the column beside a name.
    public static func typeName(_ type: ShellValueType) -> StaticString {
        switch type {
            case .void: return "Void"
            case .boolean: return "Bool"
            case .number: return "UInt64"
            case .text: return "String"
            case .record: return "Record"
            case .sequence: return "[Any]"
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
