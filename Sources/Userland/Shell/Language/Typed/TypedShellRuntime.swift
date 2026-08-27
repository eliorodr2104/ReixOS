//
//  TypedShellRuntime.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public struct TypedShellRuntime {
    private struct Binding {
        let name : ShellText
        var value: ShellValue
    }

    private var bindings      = InlineArray<8, Binding?>(repeating: nil)
    private var bindingCount  = 0
    private var sequenceArena : UnsafeMutablePointer<TypedShellSequenceArena>?

    public init() {}

    public func sequence(
          for value: ShellValue,
          in arena : TypedShellSequenceArena
    ) -> ShellSequence? {
        guard case .sequence(let handle) = value, handle >= 0, handle < arena.count else { return nil }
        return arena.sequences[handle]
    }

    public mutating func execute(
        _ program : TypedShellProgram,
          source    : UnsafePointer<UInt8>,
          count     : Int,
          signatures: UnsafeBufferPointer<TypedShellSignature?>,
          arena     : inout TypedShellSequenceArena,
          invoke    : (TypedShellInvocation) -> TypedShellInvocationResult
    ) -> Result<ShellValue, TypedShellFailure> {
        compactSequences(in: &arena)
        return withUnsafeMutablePointer(to: &arena) { attached in
            sequenceArena = attached
            defer { sequenceArena = nil }
            return executeAttached(program, source: source, count: count, signatures: signatures, invoke: invoke)
        }
    }

    private mutating func executeAttached(
        _ program : TypedShellProgram,
          source    : UnsafePointer<UInt8>,
          count     : Int,
          signatures: UnsafeBufferPointer<TypedShellSignature?>,
          invoke    : (TypedShellInvocation) -> TypedShellInvocationResult
    ) -> Result<ShellValue, TypedShellFailure> {
        var last: ShellValue = .void
        for index in 0..<program.count {
            guard let statement = program.statements[index] else { return .failure(.programLimit) }
            switch evaluate(statement.expression, program, source, count, signatures, nil, nil, invoke) {
                case .failure(let failure): return .failure(failure)
                case .success(let value):
                    last = value
                    if let binding = statement.binding {
                        guard let name = text(binding, source, count), set(name, value) else {
                            return .failure(.programLimit)
                        }
                    }
            }
        }
        return .success(last)
    }

    private mutating func evaluate(
        _ index      : Int,
        _ program    : TypedShellProgram,
        _ source     : UnsafePointer<UInt8>,
        _ sourceCount: Int,
        _ signatures : UnsafeBufferPointer<TypedShellSignature?>,
        _ zero       : ShellValue?,
        _ one        : ShellValue?,
        _ invoke     : (TypedShellInvocation) -> TypedShellInvocationResult
    ) -> Result<ShellValue, TypedShellFailure> {
        guard index >= 0, index < program.nodeCount, let node = program.nodes[index] else { return .failure(.programLimit) }
        switch node {
            case .literal(let span):
                guard let value = text(span, source, sourceCount) else { return .failure(.syntax(column: span.start)) }
                return .success(.text(value))
            case .identifier(let span):
                if matches(span, source, "$0") { return zero.map(Result.success) ?? .failure(.unknownSymbol(ShellText("$0")!)) }
                if matches(span, source, "$1") { return one.map(Result.success) ?? .failure(.unknownSymbol(ShellText("$1")!)) }
                guard let name = text(span, source, sourceCount) else { return .failure(.syntax(column: span.start)) }
                if name.equals("nil") { return .success(.void) }
                if let value = binding(named: name) { return .success(value) }
                var call = TypedShellCallSyntax(namespace: Span(start: span.start, count: 0), name: span)
                call.count = 0
                return evaluateCall(call, program, source, sourceCount, signatures, zero, one, invoke)
            case .call(let call):
                return evaluateCall(call, program, source, sourceCount, signatures, zero, one, invoke)
            case .member(let base, let member):
                return evaluate(base, program, source, sourceCount, signatures, zero, one, invoke)
                    .flatMap { self.member($0, member, source, sourceCount) }
            case .method(let base, let name, let argument):
                return evaluate(base, program, source, sourceCount, signatures, zero, one, invoke)
                    .flatMap { self.method($0, name, argument, program, source, sourceCount, signatures, invoke) }
            case .closure:
                return .failure(.type(expected: .any, actual: .void))
            case .unaryNot(let value):
                return evaluate(value, program, source, sourceCount, signatures, zero, one, invoke).flatMap {
                    guard case .boolean(let flag) = $0 else { return .failure(.type(expected: .boolean, actual: $0.type)) }
                    return .success(.boolean(!flag))
                }
            case .binary(let operation, let lhs, let rhs):
                return evaluate(lhs, program, source, sourceCount, signatures, zero, one, invoke).flatMap { left in
                    self.evaluate(rhs, program, source, sourceCount, signatures, zero, one, invoke).flatMap { right in
                        self.compare(operation, left, right)
                    }
                }
        }
    }

    private mutating func evaluateCall(
        _ call       : TypedShellCallSyntax,
        _ program    : TypedShellProgram,
        _ source     : UnsafePointer<UInt8>,
        _ sourceCount: Int,
        _ signatures : UnsafeBufferPointer<TypedShellSignature?>,
        _ zero       : ShellValue?,
        _ one        : ShellValue?,
        _ invoke     : (TypedShellInvocation) -> TypedShellInvocationResult
    ) -> Result<ShellValue, TypedShellFailure> {
        // `name.member()` and `namespace.command()` have the same token shape.
        // A lexical binding wins, as it does in Swift; otherwise resolution
        // treats the left side as a service namespace.
        if call.namespace.count > 0,
           let baseName = text(call.namespace, source, sourceCount),
           let base     = binding(named: baseName) {
            guard call.count <= 1, call.count == 0 || call.labels[0] == nil else {
                guard let name = text(call.name, source, sourceCount) else { return .failure(.syntax(column: call.name.start)) }
                return .failure(.wrongArguments(name))
            }
            return method(
                base,
                call.name,
                call.count == 1 ? call.values[0] : nil,
                program,
                source,
                sourceCount,
                signatures,
                invoke
            )
        }
        var values = InlineArray<4, TypedShellArgument?>(repeating: nil)
        for argument in 0..<call.count {
            switch evaluate(call.values[argument], program, source, sourceCount, signatures, zero, one, invoke) {
                case .failure(let failure): return .failure(failure)
                case .success(let value):
                    let label = call.labels[argument].flatMap { text($0, source, sourceCount) }
                    values[argument] = TypedShellArgument(label: label, value: value)
            }
        }
        let resolution = resolve(call, values, source, sourceCount, signatures)
        switch resolution {
            case .failure(let failure): return .failure(failure)
            case .success(let signatureIndex):
                guard let signature = signatures[signatureIndex],
                      let ordered = ordered(values, count: call.count, for: signature)
                else { return .failure(.programLimit) }
                switch invoke(TypedShellInvocation(signatureIndex: signatureIndex, arguments: ordered, argumentCount: call.count)) {
                    case .success(let value): return .success(value)
                    case .sequence(let value): return store(value)
                    case .materializationLimit(let limit): return .failure(.materializationLimit(limit))
                    case .failure(let status): return .failure(.service(status))
                }
        }
    }

    private func resolve(
        _ call       : TypedShellCallSyntax,
        _ arguments  : InlineArray<4, TypedShellArgument?>,
        _ source     : UnsafePointer<UInt8>,
        _ sourceCount: Int,
        _ signatures : UnsafeBufferPointer<TypedShellSignature?>
    ) -> Result<Int, TypedShellFailure> {
        var found        = -1
        var matchesCount = 0
        for index in signatures.indices {
            guard let signature = signatures[index] else { continue }
            guard matches(call.name, source, signature.name),
                  call.namespace.count == 0 || matches(call.namespace, source, signature.namespace),
                  call.namespace.count > 0 || !signature.namespaceRequired,
                  accepts(signature, arguments, call.count)
            else { continue }
            found = index
            matchesCount += 1
        }
        guard let name = text(call.name, source, sourceCount) else { return .failure(.syntax(column: call.name.start)) }
        if matchesCount == 0 { return .failure(.unknownSymbol(name)) }
        if matchesCount > 1 { return .failure(.ambiguousCall(name, matchesCount)) }
        return .success(found)
    }

    private func accepts(
        _ signature: TypedShellSignature,
        _ arguments: InlineArray<4, TypedShellArgument?>,
        _ count    : Int
    ) -> Bool {
        guard signature.parameterCount >= 0, signature.parameterCount <= signature.parameters.count else { return false }
        var assigned   = InlineArray<4, Bool>(repeating: false)
        var positional = 0
        for index in 0..<count {
            guard let argument = arguments[index] else { return false }
            var selected = -1
            if let label = argument.label {
                for parameter in 0..<signature.parameterCount {
                    if let expected = signature.parameters[parameter]?.label, label.equals(expected) {
                        selected = parameter
                        break
                    }
                }
            } else {
                while positional < signature.parameterCount, signature.parameters[positional]?.requiresLabel == true { positional += 1 }
                selected = positional
                positional += 1
            }
            guard selected >= 0, selected < signature.parameterCount, !assigned[selected],
                  let parameter = signature.parameters[selected],
                  parameter.type == .any || parameter.type == argument.value.type
            else { return false }
            assigned[selected] = true
        }
        for index in 0..<signature.parameterCount {
            guard let parameter = signature.parameters[index] else { return false }
            if parameter.required && !assigned[index] { return false }
        }
        return true
    }

    private func ordered(
        _ arguments: InlineArray<4, TypedShellArgument?>,
        count: Int,
        for signature: TypedShellSignature
    ) -> InlineArray<4, TypedShellArgument?>? {
        var result     = InlineArray<4, TypedShellArgument?>(repeating: nil)
        var positional = 0
        for index in 0..<count {
            guard let argument = arguments[index] else { return nil }
            let selected: Int
            if let label = argument.label {
                var found = -1
                for parameter in 0..<signature.parameterCount {
                    if let expected = signature.parameters[parameter]?.label, label.equals(expected) { found = parameter; break }
                }
                selected = found
            } else {
                while positional < signature.parameterCount, signature.parameters[positional]?.requiresLabel == true { positional += 1 }
                selected = positional
                positional += 1
            }
            guard selected >= 0, selected < result.count, result[selected] == nil else { return nil }
            result[selected] = argument
        }
        return result
    }

    private mutating func member(
        _ base  : ShellValue,
        _ span  : Span,
        _ source: UnsafePointer<UInt8>,
        _ count : Int
    ) -> Result<ShellValue, TypedShellFailure> {
        guard let name = text(span, source, count) else { return .failure(.syntax(column: span.start)) }
        guard case .record(let object) = base else { return .failure(.type(expected: .record, actual: base.type)) }
        if name.equals("name") || name.equals("path") { return .success(.text(object.name)) }
        if name.equals("isFolder") { return .success(.boolean(object.kind == FSKind.folder.rawValue || object.kind == FSKind.container.rawValue)) }
        if name.equals("isFile") { return .success(.boolean(object.kind == FSKind.file.rawValue)) }
        return .failure(.unsupportedMember(name))
    }

    private mutating func method(
        _ base      : ShellValue,
        _ nameSpan  : Span,
        _ argument  : Int?,
        _ program   : TypedShellProgram,
        _ source    : UnsafePointer<UInt8>,
        _ count     : Int,
        _ signatures: UnsafeBufferPointer<TypedShellSignature?>,
        _ invoke    : (TypedShellInvocation) -> TypedShellInvocationResult
    ) -> Result<ShellValue, TypedShellFailure> {
        guard let name = text(nameSpan, source, count) else { return .failure(.syntax(column: nameSpan.start)) }
        if name.equals("toString") {
            guard argument == nil else { return .failure(.wrongArguments(name)) }
            switch base {
                case .text: return .success(base)
                case .number(let value):
                    var bytes  = InlineArray<128, UInt8>(repeating: 0)
                    var number = value
                    var digits = 1
                    while number >= 10 { number /= 10; digits += 1 }
                    number = value
                    var index = digits
                    while index > 0 { index -= 1; bytes[index] = UInt8(number % 10) + 0x30; number /= 10 }
                    return bytes.span.withUnsafeBufferPointer { .success(.text(ShellText($0.baseAddress!, count: digits)!)) }
                case .boolean(let flag): return .success(.text(ShellText(flag ? "true" : "false")!))
                default: return .failure(.type(expected: .any, actual: base.type))
            }
        }
        if name.equals("contains") {
            guard case .text(let haystack) = base, let argument else { return .failure(.wrongArguments(name)) }
            return evaluate(argument, program, source, count, signatures, nil, nil, invoke).flatMap {
                guard case .text(let needle) = $0 else { return .failure(.type(expected: .text, actual: $0.type)) }
                return .success(.boolean(haystack.contains(needle)))
            }
        }
        guard let arena = sequenceArena,
              case .sequence(let handle) = base, handle >= 0, handle < arena.pointee.count,
              let sequence = arena.pointee.sequences[handle], let argument,
              case .closure(let body)? = program.nodes[argument]
        else { return .failure(.type(expected: .sequence, actual: base.type)) }

        if name.equals("filter") || name.equals("map") || name.equals("compactMap") || name.equals("flatMap") {
            var output = ShellSequence()
            output.beginBatch()
            for index in 0..<sequence.count {
                guard let object = sequence.value(at: index) else { continue }
                switch evaluate(body, program, source, count, signatures, .record(object), nil, invoke) {
                    case .failure(let failure): return .failure(failure)
                    case .success(let transformed):
                        if name.equals("filter") {
                            guard case .boolean(let include) = transformed else { return .failure(.type(expected: .boolean, actual: transformed.type)) }
                            if include, case .failure(.materializationLimit(let limit)) = output.append(object) { return .failure(.materializationLimit(limit)) }
                        } else if name.equals("flatMap") {
                            guard case .sequence(let nestedHandle) = transformed,
                                  nestedHandle >= 0, nestedHandle < arena.pointee.count,
                                  let nested = arena.pointee.sequences[nestedHandle]
                            else { return .failure(.type(expected: .sequence, actual: transformed.type)) }
                            for nestedIndex in 0..<nested.count {
                                if let value = nested.value(at: nestedIndex), case .failure(.materializationLimit(let limit)) = output.append(value) {
                                    return .failure(.materializationLimit(limit))
                                }
                            }
                        } else if case .record(let mapped) = transformed {
                            if case .failure(.materializationLimit(let limit)) = output.append(mapped) { return .failure(.materializationLimit(limit)) }
                        } else if case .text(let mapped) = transformed {
                            if case .failure(.materializationLimit(let limit)) = output.append(ShellObject(kind: UInt16.max, name: mapped)) {
                                return .failure(.materializationLimit(limit))
                            }
                        } else if case .number(let mapped) = transformed {
                            var digits = InlineArray<128, UInt8>(repeating: 0)
                            var value  = mapped
                            var count  = 1
                            while value >= 10 { value /= 10; count += 1 }
                            value = mapped
                            var position = count
                            while position > 0 { position -= 1; digits[position] = UInt8(value % 10) + 0x30; value /= 10 }
                            let object = digits.span.withUnsafeBufferPointer {
                                ShellObject(kind: UInt16.max, name: ShellText($0.baseAddress!, count: count)!)
                            }
                            if case .failure(.materializationLimit(let limit)) = output.append(object) {
                                return .failure(.materializationLimit(limit))
                            }
                        } else if name.equals("compactMap"), transformed == .void {
                            continue
                        } else {
                            return .failure(.type(expected: .record, actual: transformed.type))
                        }
                }
            }
            return store(output)
        }
        if name.equals("sorted") {
            var output = sequence
            guard output.count <= ShellSequence.materializationLimit else { return .failure(.materializationLimit(ShellSequence.materializationLimit)) }
            var index = 1
            while index < output.count {
                var position = index
                while position > 0, let current = output.value(at: position), let previous = output.value(at: position - 1) {
                    let order = evaluate(body, program, source, count, signatures, .record(current), .record(previous), invoke)
                    guard case .success(.boolean(let precedes)) = order else {
                        if case .failure(let failure) = order { return .failure(failure) }
                        return .failure(.type(expected: .boolean, actual: .void))
                    }
                    guard precedes else { break }
                    output.replace(at: position, with: previous)
                    output.replace(at: position - 1, with: current)
                    position -= 1
                }
                index += 1
            }
            return store(output)
        }
        return .failure(.unsupportedMember(name))
    }

    private func compare(
        _ operation: TypedShellBinaryOperator,
        _ lhs      : ShellValue,
        _ rhs      : ShellValue
    ) -> Result<ShellValue, TypedShellFailure> {
        switch (lhs, rhs) {
            case (.text(let left), .text(let right)):
                switch operation {
                    case .equal: return .success(.boolean(left == right))
                    case .notEqual: return .success(.boolean(left != right))
                    case .less: return .success(.boolean(left < right))
                    case .greater: return .success(.boolean(right < left))
                }
            case (.number(let left), .number(let right)):
                switch operation {
                    case .equal: return .success(.boolean(left == right))
                    case .notEqual: return .success(.boolean(left != right))
                    case .less: return .success(.boolean(left < right))
                    case .greater: return .success(.boolean(left > right))
                }
            case (.boolean(let left), .boolean(let right)):
                guard operation == .equal || operation == .notEqual else { return .failure(.type(expected: .number, actual: .boolean)) }
                return .success(.boolean(operation == .equal ? left == right : left != right))
            default: return .failure(.type(expected: lhs.type, actual: rhs.type))
        }
    }

    private mutating func set(
        _ name : ShellText,
        _ value: ShellValue
    ) -> Bool {
        for index in 0..<bindingCount where bindings[index]?.name == name {
            bindings[index] = Binding(name: name, value: value)
            return true
        }
        guard bindingCount < bindings.count else { return false }
        bindings[bindingCount] = Binding(name: name, value: value)
        bindingCount += 1
        return true
    }

    private mutating func store(_ sequence: ShellSequence) -> Result<ShellValue, TypedShellFailure> {
        guard let arena = sequenceArena, arena.pointee.count < arena.pointee.sequences.count else { return .failure(.programLimit) }
        let handle = arena.pointee.count
        arena.pointee.sequences[handle] = sequence
        arena.pointee.count += 1
        return .success(.sequence(handle))
    }

    /// Keeps only sequence values retained by a binding between commands.
    ///
    /// Final values from an earlier command are presentation values, not roots.
    /// Compacting them away prevents a long-running session from consuming the
    /// per-program sequence arena while preserving explicitly bound sequences.
    private mutating func compactSequences(in arena: inout TypedShellSequenceArena) {
        var compacted    = TypedShellSequenceArena()
        var oldHandles   = InlineArray<8, Int>(repeating: -1)
        var newHandles   = InlineArray<8, Int>(repeating: -1)
        var mappingCount = 0

        for index in 0..<bindingCount {
            guard var binding = bindings[index], case .sequence(let oldHandle) = binding.value,
                  oldHandle >= 0, oldHandle < arena.count, let sequence = arena.sequences[oldHandle]
            else { continue }

            var replacement = -1
            for mapping in 0..<mappingCount where oldHandles[mapping] == oldHandle {
                replacement = newHandles[mapping]
                break
            }
            if replacement < 0, compacted.count < compacted.sequences.count {
                replacement = compacted.count
                compacted.sequences[replacement] = sequence
                compacted.count += 1
                oldHandles[mappingCount] = oldHandle
                newHandles[mappingCount] = replacement
                mappingCount += 1
            }
            if replacement >= 0 {
                binding.value = .sequence(replacement)
                bindings[index] = binding
            }
        }
        arena = compacted
    }

    private func binding(named name: ShellText) -> ShellValue? {
        for index in 0..<bindingCount where bindings[index]?.name == name { return bindings[index]?.value }
        return nil
    }

    private func text(
        _ span  : Span,
        _ source: UnsafePointer<UInt8>,
        _ count : Int
    ) -> ShellText? {
        guard span.start >= 0, span.count >= 0, span.start <= count, span.count <= count - span.start else { return nil }
        return ShellText(source + span.start, count: span.count)
    }

    private func matches(
        _ span  : Span,
        _ source: UnsafePointer<UInt8>,
        _ value : StaticString
    ) -> Bool {
        guard span.count == value.utf8CodeUnitCount else { return false }
        for index in 0..<span.count where source[span.start + index] != value.utf8Start[index] { return false }
        return true
    }
}
