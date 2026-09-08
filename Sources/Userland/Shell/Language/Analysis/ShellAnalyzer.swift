//
//  ShellAnalyzer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// Reads one revision against the catalog and says what it means.
///
/// Between the lexer, which knows bytes, and the parser, which knows programs,
/// there is the question an editor actually asks: what is this, right now, with
/// the cursor here. That question has an answer for a line no parser would
/// accept, and this gives it: roles to colour, findings to place, and what
/// would fit where the cursor is.
///
/// It runs nothing. A whole revision is read every time, bounded by what the
/// lexer reads; checkpoints and incremental work are for when a measurement
/// says they are needed.
public enum ShellAnalyzer {

    public static func analyze(
        _ source  : UnsafePointer<UInt8>,
          count   : Int,
          cursor  : Int,
          revision: UInt32,
          catalog : borrowing ShellCatalog
    ) -> ShellAnalysisSnapshot {
        var snapshot = ShellAnalysisSnapshot(revision: revision)
        let stream   = ShellLexer.scan(source, count: count)
        snapshot.completeness = stream.completeness
        snapshot.truncated = stream.truncated

        var index          = 0
        var statementStart = true
        var expectBinding  = false
        var command        = -1
        var receiver       = -1
        var argument       = 0
        var schema         = ShellTypeSchema.none
        var parentheses    = 0
        // Whether the value just read was a plain word. `memo.txt` in an
        // argument is one name, by the same rule the evaluator resolves by.
        var lastValueWasWord = false
        var bindings         = InlineArray<8, Span?>(repeating: nil)
        var bindingCount     = 0

        // What would be completed if the cursor sat right here, kept current
        // as the walk goes so open space has an answer too.
        var trailing = ShellCompletionContext(subject: .receiverOrCommand)
        var found    = false

        func mark(
            _ token: ShellToken,
            _ role : ShellSemanticRole
        ) {
            snapshot.append(ShellSemanticSpan(role: role, start: token.start, count: token.count))
        }

        func note(
            _ kind : ShellDiagnosticKind,
            _ token: ShellToken
        ) {
            snapshot.append(ShellDiagnostic(kind: kind, start: token.start, count: token.count))
        }

        func touching(_ token: ShellToken) -> Bool {
            cursor >= Int(token.start) && cursor <= token.end
        }

        /// A name still being typed is not wrong yet.
        func unresolved(
            _ token: ShellToken,
            _ kind : ShellDiagnosticKind
        ) -> ShellSemanticRole {
            guard token.state != .growing else { return .incomplete }
            note(kind, token)
            return .error
        }

        func remember(_ token: ShellToken) {
            guard bindingCount < bindings.count else { return }
            bindings[bindingCount] = token.span
            bindingCount += 1
        }

        func isBinding(_ token: ShellToken) -> Bool {
            for index in 0..<bindingCount {
                guard let binding = bindings[index] else { continue }
                if same(source, token.span, source, binding) { return true }
            }
            return false
        }

        func parameterType(of command: Int, at position: Int) -> ShellValueType {
            guard let descriptor = catalog.command(at: command),
                  position >= 0, position < descriptor.signature.parameterCount,
                  let parameter = descriptor.signature.parameters[position]
            else { return .any }
            return parameter.type
        }

        /// What the cursor would be completing if it sat inside this token.
        ///
        /// Not the same question as what comes after it: inside the verb of a
        /// call, the answer is other verbs, and one byte further along it is
        /// that verb's first argument. The first token the cursor touches
        /// wins, because that is the one being typed.
        func here(
            _ subject : ShellCompletionSubject,
            _ token   : ShellToken,
              expected: ShellValueType = .any
        ) {
            guard !found, touching(token) else { return }
            snapshot.context = ShellCompletionContext(
                subject : subject,
                start   : token.start,
                count   : token.count,
                receiver: receiver,
                command : command,
                expected: expected,
                schema  : schema
            )
            found = true
        }

        /// What would be completed in the open space after what was just read.
        func after(
            _ subject : ShellCompletionSubject,
              expected: ShellValueType = .any
        ) {
            trailing = ShellCompletionContext(
                subject : subject,
                start   : UInt16(min(cursor, Int(UInt16.max))),
                count   : 0,
                receiver: receiver,
                command : command,
                expected: expected,
                schema  : schema
            )
        }

        while index < stream.count {
            guard let token = stream.token(at: index) else { break }
            index += 1

            switch token.kind {
                case .newline:
                    mark(token, .plain)
                    statementStart = true
                    expectBinding = false
                    command = -1
                    receiver = -1
                    argument = 0
                    schema = .none
                    after(.receiverOrCommand)

                case .comma:
                    mark(token, .plain)
                    if parentheses == 0 {
                        statementStart = true
                        command = -1
                        receiver = -1
                        argument = 0
                        schema = .none
                        after(.receiverOrCommand)
                    } else {
                        after(command >= 0 ? .label : .value, expected: parameterType(of: command, at: argument))
                    }

                case .keyword:
                    mark(token, .keyword)
                    expectBinding = true
                    // The name after `let` is being invented, so there is
                    // nothing to offer for it.
                    after(.none)

                case .assign:
                    mark(token, .plain)
                    statementStart = true
                    after(.receiverOrCommand)

                case .openParenthesis:
                    parentheses += 1
                    mark(token, .plain)
                    after(.label, expected: parameterType(of: command, at: argument))

                case .closeParenthesis:
                    if parentheses > 0 { parentheses -= 1 }
                    mark(token, token.state == .invalid ? .error : .plain)
                    if token.state == .invalid { note(.unbalanced, token) }
                    after(.value)

                case .openBrace, .closeBrace:
                    mark(token, token.state == .invalid ? .error : .closure)
                    if token.state == .invalid { note(.unbalanced, token) }
                    after(.value)

                case .text:
                    if token.state == .unterminated {
                        mark(token, .incomplete)
                        note(.unterminatedText, token)
                    } else {
                        mark(token, .text)
                    }
                    argument += 1
                    lastValueWasWord = false
                    here(.value, token, expected: parameterType(of: command, at: argument - 1))
                    after(.value, expected: parameterType(of: command, at: argument))

                case .number:
                    mark(token, .number)
                    lastValueWasWord = false
                    argument += 1
                    here(.value, token, expected: parameterType(of: command, at: argument - 1))
                    after(.value, expected: parameterType(of: command, at: argument))

                case .path:
                    mark(token, .path)
                    lastValueWasWord = false
                    argument += 1
                    here(.value, token, expected: parameterType(of: command, at: argument - 1))
                    after(.value, expected: parameterType(of: command, at: argument))

                case .placeholder:
                    mark(token, .variable)
                    lastValueWasWord = false
                    here(.value, token)
                    after(.value)

                case .unknown:
                    mark(token, .error)
                    note(.invalidByte, token)
                    here(.none, token)
                    after(.none)

                case .operatorSymbol, .colon:
                    mark(token, .plain)
                    after(.value, expected: parameterType(of: command, at: argument))

                case .dot:
                    mark(token, .plain)
                    if lastValueWasWord, let next = stream.token(at: index), next.kind == .name {
                        index += 1
                        mark(next, .plain)
                        here(.value, next, expected: parameterType(of: command, at: max(0, argument - 1)))
                        after(.value, expected: parameterType(of: command, at: argument))
                        continue
                    }
                    // What follows a dot is a member of what came before it,
                    // unless what came before it was a receiver.
                    guard let next = stream.token(at: index), next.kind == .name else {
                        after(receiver >= 0 ? .command : .member)
                        continue
                    }
                    index += 1
                    if receiver >= 0 {
                        if let resolved = commandIndex(catalog, source, next.span, in: receiver) {
                            mark(next, .command)
                            command = resolved
                            schema = catalog.command(at: resolved)?.schema ?? .none
                            argument = 0
                        } else {
                            mark(next, unresolved(next, .unknownCommand))
                        }
                        here(.command, next)
                        after(command >= 0 && parentheses == 0 ? .value : .label, expected: parameterType(of: command, at: 0))
                        receiver = -1
                        statementStart = false
                    } else {
                        if knowsMember(catalog, source, next.span, of: schema) {
                            mark(next, .member)
                        } else {
                            mark(next, unresolved(next, .unknownMember))
                        }
                        here(.member, next)
                        after(.value)
                    }

                case .name:
                    if expectBinding {
                        mark(token, .variable)
                        remember(token)
                        expectBinding = false
                        here(.none, token)
                        after(.none)
                        continue
                    }

                    // A label is a name wearing a colon, and only inside a
                    // call somebody wrote out.
                    if let next = stream.token(at: index), next.kind == .colon, parentheses > 0 {
                        if command >= 0, !knowsLabel(catalog, source, token.span, of: command) {
                            mark(token, unresolved(token, .unknownLabel))
                        } else {
                            mark(token, .label)
                        }
                        here(.label, token)
                        after(.value, expected: parameterType(of: command, at: argument))
                        continue
                    }

                    if statementStart {
                        statementStart = false
                        if let namespace = namespaceIndex(catalog, source, token.span) {
                            mark(token, .namespace)
                            receiver = namespace
                            lastValueWasWord = false
                            here(.receiverOrCommand, token)
                            after(.receiverOrCommand)
                            continue
                        }
                        if let resolved = commandIndex(catalog, source, token.span, in: nil) {
                            mark(token, .command)
                            command = resolved
                            schema = catalog.command(at: resolved)?.schema ?? .none
                            argument = 0
                            lastValueWasWord = false
                            here(.receiverOrCommand, token)
                            after(.value, expected: parameterType(of: resolved, at: 0))
                            continue
                        }
                        if isBinding(token) {
                            mark(token, .variable)
                            lastValueWasWord = false
                            here(.receiverOrCommand, token)
                            after(.value)
                            continue
                        }
                        mark(token, unresolved(token, .unknownCommand))
                        here(.receiverOrCommand, token)
                        after(.receiverOrCommand)
                        continue
                    }

                    // Anywhere else a name is a value: something bound, or a
                    // word, which is what an unquoted argument is.
                    let bound = isBinding(token)
                    mark(token, bound ? .variable : .plain)
                    lastValueWasWord = !bound
                    argument += 1
                    here(.value, token, expected: parameterType(of: command, at: argument - 1))
                    after(.value, expected: parameterType(of: command, at: argument))
            }
        }

        if !found {
            snapshot.context = trailing
        }
        return snapshot
    }

    // MARK: Asking the catalog

    private static func namespaceIndex(
        _ catalog: borrowing ShellCatalog,
        _ source : UnsafePointer<UInt8>,
        _ span   : Span
    ) -> Int? {
        for index in 0..<catalog.namespaceCount {
            guard let receiver = catalog.namespace(at: index) else { continue }
            if spells(source, span, receiver.name) { return index }
        }
        return nil
    }

    /// The command a name resolves to, in a receiver or without one.
    ///
    /// Without a receiver the answer has to be the only one, and a command
    /// that insists on being named does not answer at all: the same rule
    /// resolution runs by, asked earlier.
    private static func commandIndex(
        _ catalog  : borrowing ShellCatalog,
        _ source   : UnsafePointer<UInt8>,
        _ span     : Span,
          in owner : Int?
    ) -> Int? {
        var found = -1
        var count = 0
        for index in 0..<catalog.count {
            guard let descriptor = catalog.command(at: index),
                  spells(source, span, descriptor.signature.name)
            else { continue }
            if let owner {
                guard let receiver = catalog.receiver(ofCommandAt: index),
                      let named = catalog.namespace(at: owner),
                      sameName(receiver.name, named.name)
                else { continue }
            } else if descriptor.signature.namespaceRequired {
                continue
            }
            found = index
            count += 1
        }
        return count == 1 ? found : nil
    }

    private static func knowsLabel(
        _ catalog: borrowing ShellCatalog,
        _ source : UnsafePointer<UInt8>,
        _ span   : Span,
          of index: Int
    ) -> Bool {
        guard let descriptor = catalog.command(at: index) else { return false }
        for position in 0..<descriptor.signature.parameterCount {
            guard let parameter = descriptor.signature.parameters[position] else { continue }
            if spells(source, span, parameter.label) { return true }
        }
        return false
    }

    /// A member of the value, or one of the methods the evaluator answers on
    /// any value. A shape nobody named yet takes whatever it is given: there
    /// is nothing to hold it to.
    private static func knowsMember(
        _ catalog : borrowing ShellCatalog,
        _ source  : UnsafePointer<UInt8>,
        _ span    : Span,
          of schema: ShellTypeSchema
    ) -> Bool {
        for index in 0..<ShellCatalog.methodCount {
            guard let method = ShellCatalog.method(at: index) else { continue }
            if spells(source, span, method.name) { return true }
        }
        guard schema != .none else { return true }
        for index in 0..<ShellCatalog.memberCount(of: schema) {
            guard let member = ShellCatalog.member(of: schema, at: index) else { continue }
            if spells(source, span, member.name) { return true }
        }
        return false
    }

    // MARK: Bytes

    private static func spells(
        _ source: UnsafePointer<UInt8>,
        _ span  : Span,
        _ name  : StaticString
    ) -> Bool {
        guard span.count == name.utf8CodeUnitCount else { return false }
        for index in 0..<span.count where source[span.start + index] != name.utf8Start[index] {
            return false
        }
        return true
    }

    private static func same(
        _ left      : UnsafePointer<UInt8>,
        _ leftSpan  : Span,
        _ right     : UnsafePointer<UInt8>,
        _ rightSpan : Span
    ) -> Bool {
        guard leftSpan.count == rightSpan.count else { return false }
        for index in 0..<leftSpan.count
            where left[leftSpan.start + index] != right[rightSpan.start + index] {
            return false
        }
        return true
    }

    private static func sameName(
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
