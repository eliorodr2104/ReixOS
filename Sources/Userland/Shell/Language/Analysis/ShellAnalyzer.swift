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
        var expectsOperand = false
        var expectedOperand = ShellValueType.any
        // Whether the value just read was a plain word. `memo.txt` in an
        // argument is one name, by the same rule the evaluator resolves by.
        var lastValueWasWord = false
        // One frame per open closure: what `$0` stands for inside it, what the
        // value was before it opened, and which method is waiting for what it
        // answers. A stack rather than a slot, so a closure inside a closure
        // is read the same way as the first one.
        var closures      = InlineArray<4, ShellClosureFrame?>(repeating: nil)
        var closureDepth  = 0
        var pendingMethod : ShellMethodDescriptor?
        var pendingReceiver = ShellTypeSchema.none

        var closureElement: ShellTypeSchema {
            closureDepth > 0 ? (closures[closureDepth - 1]?.element ?? .none) : .none
        }
        var closureParameter: Span? {
            closureDepth > 0 ? closures[closureDepth - 1]?.parameter : nil
        }
        var closureParameterCount: UInt8 {
            closureDepth > 0 ? (closures[closureDepth - 1]?.parameterCount ?? 0) : 0
        }
        var closureExpected: ShellValueType {
            closureDepth > 0 ? (closures[closureDepth - 1]?.method?.closureResult ?? .any) : .any
        }
        var bindings              = InlineArray<8, Span?>(repeating: nil)
        var bindingTypes          = InlineArray<8, ShellTypeSchema>(repeating: .none)
        var bindingSnapshotIndices = InlineArray<8, Int>(repeating: -1)
        var bindingCount          = 0
        var pendingBinding       : Int?

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

        @discardableResult
        func remember(
            _ token: ShellToken,
              type : ShellTypeSchema
        ) -> Int? {
            guard bindingCount < bindings.count else { return nil }
            let local = bindingCount
            bindings[local] = token.span
            bindingTypes[local] = type
            bindingSnapshotIndices[local] = snapshot.remember(ShellBindingInfo(
                start      : token.start,
                count      : token.count,
                type       : type,
                visibleFrom: UInt16(clamping: token.end)
            )) ?? -1
            bindingCount += 1
            return local
        }

        func bindingIndex(_ token: ShellToken) -> Int? {
            for index in 0..<bindingCount {
                guard let binding = bindings[index] else { continue }
                if same(source, token.span, source, binding) { return index }
            }
            return nil
        }

        func finishPendingBinding() {
            guard let local = pendingBinding else { return }
            bindingTypes[local] = schema
            let snapshotIndex = bindingSnapshotIndices[local]
            if snapshotIndex >= 0 { snapshot.updateBinding(at: snapshotIndex, type: schema) }
            pendingBinding = nil
        }

        func commandSchema(at index: Int) -> ShellTypeSchema {
            guard let descriptor = catalog.command(at: index) else { return .none }
            return descriptor.schema.isEmptyType
                ? ShellTypeSchema(valueType: descriptor.signature.result)
                : descriptor.schema
        }

        func parameterType(of command: Int, at position: Int) -> ShellValueType {
            guard let descriptor = catalog.command(at: command),
                  position >= 0, position < descriptor.signature.parameterCount,
                  let parameter = descriptor.signature.parameters[position]
            else { return .any }
            return parameter.type
        }

        func parameterSubject(of command: Int, at position: Int) -> ShellParameterSubject {
            guard let descriptor = catalog.command(at: command),
                  position >= 0, position < descriptor.signature.parameterCount,
                  let parameter = descriptor.signature.parameters[position]
            else { return .value }
            return parameter.subject
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
                argument: max(0, argument - 1),
                expected: expected,
                schema  : schema,
                scope   : closureElement,
                scopeCount: closureParameterCount,
                scopeName: closureParameter
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
                argument: argument,
                expected: expected,
                schema  : schema,
                scope   : closureElement,
                scopeCount: closureParameterCount,
                scopeName: closureParameter
            )
        }

        while index < stream.count {
            guard let token = stream.token(at: index) else { break }
            index += 1

            switch token.kind {
                case .newline:
                    mark(token, .plain)
                    if closureDepth > 0 || parentheses > 0 || expectsOperand {
                        // A physical line break inside an unfinished
                        // expression is whitespace, not a new shell
                        // statement. This keeps closure scope and receiver
                        // types alive in editor mode.
                        after(.value, expected: expectsOperand ? expectedOperand : closureExpected)
                        continue
                    }
                    finishPendingBinding()
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
                        finishPendingBinding()
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
                    schema = .none
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

                case .openBrace:
                    expectsOperand = false
                    mark(token, token.state == .invalid ? .error : .closure)
                    if token.state == .invalid { note(.unbalanced, token) }
                    // `{ entry in ... }` names the element, and the name is a
                    // value everywhere in the body.
                    let outerBindingCount = bindingCount
                    let element = schema.elementType
                    var parameter: Span?
                    var parameterBinding = -1
                    if let named = stream.token(at: index), named.kind == .name,
                       let keyword = stream.token(at: index + 1), keyword.kind == .name,
                       spells(source, keyword.span, "in") {
                        index += 2
                        mark(named, .variable)
                        if let local = remember(named, type: element) {
                            parameterBinding = bindingSnapshotIndices[local]
                        }
                        parameter = named.span
                        mark(keyword, .keyword)
                    }
                    let requiredType = pendingMethod?.closureResult ?? .any
                    if closureDepth < closures.count {
                        closures[closureDepth] = ShellClosureFrame(
                            element  : element,
                            outer    : schema,
                            method   : pendingMethod,
                            receiver : pendingReceiver,
                            parameter: parameter,
                            parameterCount: pendingMethod?.closureParameters ?? 0,
                            outerBindingCount: outerBindingCount,
                            parameterBinding: parameterBinding
                        )
                        closureDepth += 1
                    }
                    pendingMethod = nil
                    pendingReceiver = .none
                    schema = .none
                    after(.value, expected: requiredType)

                case .closeBrace:
                    expectsOperand = false
                    mark(token, token.state == .invalid ? .error : .closure)
                    if token.state == .invalid { note(.unbalanced, token) }
                    // What the closure answered is the last thing in it, and
                    // that is what tells `map` what it is a list of.
                    let answered = schema
                    if closureDepth > 0, let frame = closures[closureDepth - 1] {
                        closureDepth -= 1
                        bindingCount = frame.outerBindingCount
                        if frame.parameterBinding >= 0 {
                            snapshot.closeBinding(at: frame.parameterBinding, before: Int(token.start))
                        }
                        schema = frame.method?.resultType(on: frame.receiver, closure: answered)
                            ?? frame.outer
                        closures[closureDepth] = nil
                    }
                    after(.value)

                case .text:
                    let valueExpected = expectsOperand ? expectedOperand : parameterType(of: command, at: argument)
                    expectsOperand = false
                    if token.state == .unterminated {
                        mark(token, parameterSubject(of: command, at: argument) == .path ? .path : .incomplete)
                        note(.unterminatedText, token)
                    } else {
                        mark(token, parameterSubject(of: command, at: argument) == .path ? .path : .text)
                    }
                    argument += 1
                    lastValueWasWord = false
                    if command < 0 { schema = .text }
                    here(.value, token, expected: valueExpected)
                    after(.value, expected: parameterType(of: command, at: argument))

                case .number:
                    let valueExpected = expectsOperand ? expectedOperand : parameterType(of: command, at: argument)
                    expectsOperand = false
                    mark(token, .number)
                    lastValueWasWord = false
                    if command < 0 { schema = .number }
                    argument += 1
                    here(.value, token, expected: valueExpected)
                    after(.value, expected: parameterType(of: command, at: argument))

                case .path:
                    let valueExpected = expectsOperand ? expectedOperand : parameterType(of: command, at: argument)
                    expectsOperand = false
                    mark(token, .path)
                    lastValueWasWord = false
                    if command < 0 { schema = .text }
                    argument += 1
                    here(.value, token, expected: valueExpected)
                    after(.value, expected: parameterType(of: command, at: argument))

                case .placeholder:
                    let valueExpected = expectsOperand ? expectedOperand : .any
                    expectsOperand = false
                    mark(token, .variable)
                    lastValueWasWord = false
                    schema = closureElement
                    here(.value, token, expected: valueExpected)
                    after(.value)

                case .unknown:
                    mark(token, .error)
                    note(.invalidByte, token)
                    here(.none, token)
                    after(.none)

                case .operatorSymbol:
                    mark(token, .keyword)
                    if spells(source, token.span, "&&") || spells(source, token.span, "||")
                        || spells(source, token.span, "&") || spells(source, token.span, "|") {
                        here(.value, token, expected: .boolean)
                        expectsOperand = true
                        expectedOperand = .boolean
                        statementStart = true
                        schema = .none
                        after(.value, expected: .boolean)
                    } else if spells(source, token.span, "!") {
                        here(.value, token, expected: .boolean)
                        expectsOperand = true
                        expectedOperand = .boolean
                        statementStart = true
                        schema = .none
                        after(.value, expected: .boolean)
                    } else {
                        let operand = schema.valueType
                        here(.value, token, expected: operand)
                        expectsOperand = true
                        expectedOperand = operand
                        statementStart = true
                        schema = .none
                        after(.value, expected: operand)
                    }

                case .colon:
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
                        after(
                            receiver >= 0 ? .command : .member,
                            expected: expectsOperand ? expectedOperand : .any
                        )
                        continue
                    }
                    index += 1
                    if receiver >= 0 {
                        let commandExpected = expectsOperand ? expectedOperand : .any
                        if let resolved = commandIndex(catalog, source, next.span, in: receiver) {
                            expectsOperand = false
                            mark(next, .command)
                            command = resolved
                            schema = commandSchema(at: resolved)
                            argument = 0
                        } else {
                            mark(next, unresolved(next, .unknownCommand))
                        }
                        here(.command, next, expected: commandExpected)
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
                        // Reaching into a value gives another value, and the
                        // next dot is about that one. A method that takes a
                        // closure waits for it: what it answers depends on
                        // what the closure says.
                        if let method = methodDescriptor(source, next.span, of: schema),
                           method.argument == .closure {
                            pendingMethod = method
                            pendingReceiver = schema
                        } else {
                            schema = memberType(source, next.span, of: schema)
                        }
                        after(.value)
                    }

                case .name:
                    if expectBinding {
                        mark(token, .variable)
                        pendingBinding = remember(token, type: .none)
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

                    let expressionExpected = expectsOperand
                        ? expectedOperand
                        : parameterType(of: command, at: argument)

                    if spells(source, token.span, "true") || spells(source, token.span, "false")
                        || spells(source, token.span, "nil") {
                        expectsOperand = false
                        mark(token, .keyword)
                        schema = spells(source, token.span, "nil") ? .none : .boolean
                        statementStart = false
                        lastValueWasWord = false
                        argument += 1
                        here(.value, token, expected: expressionExpected)
                        after(.value, expected: parameterType(of: command, at: argument))
                        continue
                    }

                    if statementStart {
                        statementStart = false
                        if let namespace = namespaceIndex(catalog, source, token.span) {
                            mark(token, .namespace)
                            receiver = namespace
                            lastValueWasWord = false
                            here(.receiverOrCommand, token, expected: expressionExpected)
                            after(.receiverOrCommand)
                            continue
                        }
                        if let resolved = commandIndex(catalog, source, token.span, in: nil) {
                            expectsOperand = false
                            mark(token, .command)
                            command = resolved
                            schema = commandSchema(at: resolved)
                            argument = 0
                            lastValueWasWord = false
                            here(.receiverOrCommand, token, expected: expressionExpected)
                            after(.value, expected: parameterType(of: resolved, at: 0))
                            continue
                        }
                        if let binding = bindingIndex(token) {
                            expectsOperand = false
                            mark(token, .variable)
                            schema = bindingTypes[binding]
                            lastValueWasWord = false
                            here(.receiverOrCommand, token, expected: expressionExpected)
                            after(.value)
                            continue
                        }
                        mark(token, unresolved(token, .unknownCommand))
                        here(.receiverOrCommand, token, expected: expressionExpected)
                        after(.receiverOrCommand)
                        continue
                    }

                    // Anywhere else a name is a value: something bound, or a
                    // word, which is what an unquoted argument is.
                    let binding = bindingIndex(token)
                    expectsOperand = false
                    let role: ShellSemanticRole
                    if binding != nil {
                        role = .variable
                    } else if parameterSubject(of: command, at: argument) == .path {
                        role = .path
                    } else {
                        role = .plain
                    }
                    mark(token, role)
                    if let closureParameter, same(source, token.span, source, closureParameter) {
                        schema = closureElement
                    } else if let binding {
                        schema = bindingTypes[binding]
                    }
                    lastValueWasWord = binding == nil
                    argument += 1
                    here(.value, token, expected: parameterType(of: command, at: argument - 1))
                    after(.value, expected: parameterType(of: command, at: argument))
            }
        }

        finishPendingBinding()

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
    /// A member or a method of this type, and of no other.
    ///
    /// A value whose type nobody could work out takes whatever it is given:
    /// there is nothing to hold it to.
    private static func knowsMember(
        _ catalog : borrowing ShellCatalog,
        _ source  : UnsafePointer<UInt8>,
        _ span    : Span,
          of schema: ShellTypeSchema
    ) -> Bool {
        guard !schema.isEmptyType else { return true }
        for index in 0..<ShellCatalog.memberCount(of: schema) {
            guard let member = ShellCatalog.member(of: schema, at: index) else { continue }
            if spells(source, span, member.name) { return true }
        }
        for index in 0..<ShellCatalog.methodCount(of: schema) {
            guard let method = ShellCatalog.method(of: schema, at: index) else { continue }
            if spells(source, span, method.name) { return true }
        }
        return false
    }

    /// What reaching into a value gives back, so the next dot can be offered
    /// against it.
    ///
    /// A method that takes a closure cannot be answered here: what `map` gives
    /// back depends on what the closure says, and the closure has not been
    /// read yet. Those are resolved where they close.
    private static func memberType(
        _ source  : UnsafePointer<UInt8>,
        _ span    : Span,
          of schema: ShellTypeSchema
    ) -> ShellTypeSchema {
        for index in 0..<ShellCatalog.memberCount(of: schema) {
            guard let member = ShellCatalog.member(of: schema, at: index) else { continue }
            if spells(source, span, member.name) { return member.type }
        }
        for index in 0..<ShellCatalog.methodCount(of: schema) {
            guard let method = ShellCatalog.method(of: schema, at: index) else { continue }
            if spells(source, span, method.name) { return method.resultType(on: schema) }
        }
        return .none
    }

    /// The method a name stands for on this type, when it is one.
    private static func methodDescriptor(
        _ source  : UnsafePointer<UInt8>,
        _ span    : Span,
          of schema: ShellTypeSchema
    ) -> ShellMethodDescriptor? {
        for index in 0..<ShellCatalog.methodCount(of: schema) {
            guard let method = ShellCatalog.method(of: schema, at: index) else { continue }
            if spells(source, span, method.name) { return method }
        }
        return nil
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

/// One open closure, while a revision is being read.
///
/// Held on a stack so nesting reads like the first level: what one element is,
/// what the value was outside, and the method waiting to hear what the body
/// answers.
internal struct ShellClosureFrame {
    let element  : ShellTypeSchema
    let outer    : ShellTypeSchema
    let method   : ShellMethodDescriptor?
    let receiver : ShellTypeSchema
    let parameter: Span?
    let parameterCount: UInt8
    let outerBindingCount: Int
    let parameterBinding: Int
}
