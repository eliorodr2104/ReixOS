//
//  TypedShellParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import ReixABI

public enum TypedShellParser {
    public static func completeness(
        _ source: UnsafePointer<UInt8>,
          count : Int
    ) -> ShellCompleteness {
        guard count >= 0 else { return .invalid(column: 0) }
        var parentheses = 0
        var braces      = 0
        var quoted      = false
        var index       = 0
        while index < count {
            let byte = source[index]
            if byte == quote { quoted.toggle() }
            if !quoted {
                if byte == open { parentheses += 1 }
                if byte == close {
                    guard parentheses > 0 else { return .invalid(column: index) }
                    parentheses -= 1
                }
                if byte == openBrace { braces += 1 }
                if byte == closeBrace {
                    guard braces > 0 else { return .invalid(column: index) }
                    braces -= 1
                }
            }
            index += 1
        }
        if quoted || parentheses > 0 || braces > 0 {
            return .incomplete(indent: parentheses + braces)
        }
        return .complete
    }

    public static func parse(
        _ source: UnsafePointer<UInt8>,
          count : Int
    ) -> Result<TypedShellProgram, TypedShellFailure> {
        switch completeness(source, count: count) {
            case .invalid(let column): return .failure(.syntax(column: column))
            case .incomplete: return .failure(.incomplete)
            case .complete: break
        }
        var parser = Parser(source: source, end: count)
        return parser.program()
    }

    private struct Parser {
        let source : UnsafePointer<UInt8>
        let end    : Int
        var cursor = 0
        var result = TypedShellProgram()

        mutating func program() -> Result<TypedShellProgram, TypedShellFailure> {
            spaces()
            guard cursor < end else { return .failure(.syntax(column: cursor)) }
            while cursor < end {
                let binding = bindingName()
                guard let expression = expression(compactRoot: true) else {
                    return .failure(.syntax(column: cursor))
                }
                guard result.append(TypedShellStatement(binding: binding, expression: expression)) else {
                    return .failure(.programLimit)
                }
                spaces()
                guard cursor < end else { break }
                guard source[cursor] == comma else { return .failure(.syntax(column: cursor)) }
                cursor += 1
                spaces()
                guard cursor < end else { return .failure(.syntax(column: cursor)) }
            }
            return .success(result)
        }

        mutating func bindingName() -> Span? {
            let saved = cursor
            guard let keyword = name(), equals(keyword, "let") else { cursor = saved; return nil }
            spaces()
            guard let binding = name() else { cursor = saved; return nil }
            spaces()
            guard take(equalsByte) else { cursor = saved; return nil }
            spaces()
            return binding
        }

        mutating func expression(compactRoot: Bool) -> Int? {
            guard var lhs = primary(compactRoot: compactRoot) else { return nil }
            while true {
                spaces()
                if take(dot) {
                    guard let member = name() else { return nil }
                    spaces()
                    if cursor < end, source[cursor] == open {
                        guard let argument = parenthesizedSingleArgument() else { return nil }
                        guard let node = result.append(.method(base: lhs, name: member, argument: argument)) else { return nil }
                        lhs = node
                    } else if cursor < end, source[cursor] == openBrace {
                        guard let closure = closure() else { return nil }
                        guard let node = result.append(.method(base: lhs, name: member, argument: closure)) else { return nil }
                        lhs = node
                    } else {
                        guard let node = result.append(.member(base: lhs, name: member)) else { return nil }
                        lhs = node
                    }
                    continue
                }
                if takePair(exclamation, equalsByte) {
                    guard let rhs = expression(compactRoot: false), let node = result.append(.binary(.notEqual, lhs, rhs)) else { return nil }
                    return node
                }
                if takePair(equalsByte, equalsByte) {
                    guard let rhs = expression(compactRoot: false), let node = result.append(.binary(.equal, lhs, rhs)) else { return nil }
                    return node
                }
                if take(less) {
                    guard let rhs = expression(compactRoot: false), let node = result.append(.binary(.less, lhs, rhs)) else { return nil }
                    return node
                }
                if take(greater) {
                    guard let rhs = expression(compactRoot: false), let node = result.append(.binary(.greater, lhs, rhs)) else { return nil }
                    return node
                }
                break
            }
            return lhs
        }

        mutating func primary(compactRoot: Bool) -> Int? {
            spaces()
            if take(exclamation) {
                guard let value = expression(compactRoot: false) else { return nil }
                return result.append(.unaryNot(value))
            }
            if cursor < end, source[cursor] == quote {
                guard let span = quoted() else { return nil }
                return result.append(.literal(span))
            }
            if cursor < end, source[cursor] == openBrace { return closure() }
            guard let first = name(allowDollar: true) else { return nil }
            let headEnd = cursor
            spaces()
            let separatedFromHead = cursor > headEnd

            var namespace = Span(start: first.start, count: 0)
            var verb      = first
            let saved     = cursor
            if take(dot), let second = name() {
                spaces()
                if cursor < end, source[cursor] == open {
                    namespace = first
                    verb = second
                } else {
                    cursor = saved
                }
            }

            if cursor < end, source[cursor] == open {
                return call(namespace: namespace, name: verb, canonical: true)
            }
            if compactRoot, shouldBeginCompactArgument(allowLeadingDot: separatedFromHead) {
                return call(namespace: namespace, name: verb, canonical: false)
            }
            return result.append(.identifier(first))
        }

        mutating func call(
              namespace: Span,
              name     : Span,
              canonical: Bool
        ) -> Int? {
            var call = TypedShellCallSyntax(namespace: namespace, name: name)
            if canonical {
                guard take(open) else { return nil }
                spaces()
                if take(close) { return result.append(.call(call)) }
                while true {
                    spaces()
                    let saved = cursor
                    var label : Span?
                    if let candidate = self.name() {
                        spaces()
                        if take(colon) { label = candidate; spaces() } else { cursor = saved }
                    }
                    guard let value = expression(compactRoot: false), call.count < call.values.count else { return nil }
                    call.labels[call.count] = label
                    call.values[call.count] = value
                    call.count += 1
                    spaces()
                    if take(close) { break }
                    guard take(comma) else { return nil }
                }
            } else {
                while cursor < end {
                    spaces()
                    if cursor >= end || source[cursor] == comma || source[cursor] == closeBrace { break }
                    if source[cursor] == dot || source[cursor] == less || source[cursor] == greater { break }
                    var label : Span?
                    let saved = cursor
                    if let candidate = self.name() {
                        if isCompactLabel(candidate) {
                            spaces()
                            if shouldBeginCompactArgument(allowLeadingDot: true) { label = candidate } else { cursor = saved }
                        } else {
                            cursor = saved
                        }
                    }
                    let span: Span
                    if cursor < end, source[cursor] == quote {
                        guard let value = quoted() else { return nil }
                        span = value
                    } else {
                        guard let value = bare() else { return nil }
                        span = value
                    }
                    guard let value = result.append(.literal(span)), call.count < call.values.count else { return nil }
                    call.labels[call.count] = label
                    call.values[call.count] = value
                    call.count += 1
                }
            }
            return result.append(.call(call))
        }

        mutating func parenthesizedSingleArgument() -> Int?? {
            guard take(open) else { return nil }
            spaces()
            if take(close) { return .some(nil) }
            guard let value = expression(compactRoot: false) else { return nil }
            spaces()
            guard take(close) else { return nil }
            return .some(value)
        }

        mutating func closure() -> Int? {
            guard take(openBrace) else { return nil }
            spaces()
            guard let body = expression(compactRoot: false) else { return nil }
            spaces()
            guard take(closeBrace) else { return nil }
            return result.append(.closure(body))
        }

        mutating func quoted() -> Span? {
            guard take(quote) else { return nil }
            let start = cursor
            while cursor < end, source[cursor] != quote { cursor += 1 }
            guard take(quote) else { return nil }
            return Span(start: start, count: cursor - start - 1)
        }

        mutating func bare() -> Span? {
            let start = cursor
            while cursor < end {
                let byte = source[cursor]
                if byte == space || byte == comma || byte == dot || byte == close || byte == closeBrace { break }
                cursor += 1
            }
            return cursor > start ? Span(start: start, count: cursor - start) : nil
        }

        mutating func name(allowDollar: Bool = false) -> Span? {
            spaces()
            let start = cursor
            if allowDollar, cursor + 1 < end, source[cursor] == dollar,
               source[cursor + 1] >= zero, source[cursor + 1] <= nine {
                cursor += 2
                return Span(start: start, count: 2)
            }
            guard cursor < end, isNameStart(source[cursor]) else { return nil }
            cursor += 1
            while cursor < end, isNameBody(source[cursor]) { cursor += 1 }
            return Span(start: start, count: cursor - start)
        }

        mutating func spaces() {
            while cursor < end, source[cursor] == space || source[cursor] == lineFeed || source[cursor] == carriageReturn { cursor += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            guard cursor < end, source[cursor] == byte else { return false }
            cursor += 1
            return true
        }

        mutating func takePair(
            _ first : UInt8,
            _ second: UInt8
        ) -> Bool {
            guard cursor + 1 < end, source[cursor] == first, source[cursor + 1] == second else { return false }
            cursor += 2
            return true
        }

        func shouldBeginCompactArgument(allowLeadingDot: Bool = false) -> Bool {
            guard cursor < end else { return false }
            let byte = source[cursor]
            return byte == quote || isNameStart(byte) || (byte >= zero && byte <= nine) || (allowLeadingDot && byte == dot)
        }

        func isCompactLabel(_ span: Span) -> Bool {
            equals(span, "from") || equals(span, "to") || equals(span, "at") || equals(span, "in")
        }

        func equals(
            _ span : Span,
            _ value: StaticString
        ) -> Bool {
            guard span.count == value.utf8CodeUnitCount else { return false }
            for index in 0..<span.count where source[span.start + index] != value.utf8Start[index] { return false }
            return true
        }
    }

    private static func isNameStart(_ byte: UInt8) -> Bool {
        (byte >= upperA && byte <= upperZ) || (byte >= lowerA && byte <= lowerZ) || byte == underscore
    }

    private static func isNameBody(_ byte: UInt8) -> Bool { isNameStart(byte) || (byte >= zero && byte <= nine) }

    private static let space         : UInt8 = 0x20
    private static let lineFeed      : UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let comma         : UInt8 = 0x2C
    private static let dot           : UInt8 = 0x2E
    private static let colon         : UInt8 = 0x3A
    private static let equalsByte    : UInt8 = 0x3D
    private static let exclamation   : UInt8 = 0x21
    private static let less          : UInt8 = 0x3C
    private static let greater       : UInt8 = 0x3E
    private static let quote         : UInt8 = 0x22
    private static let open          : UInt8 = 0x28
    private static let close         : UInt8 = 0x29
    private static let openBrace     : UInt8 = 0x7B
    private static let closeBrace    : UInt8 = 0x7D
    private static let dollar        : UInt8 = 0x24
    private static let underscore    : UInt8 = 0x5F
    private static let upperA        : UInt8 = 0x41
    private static let upperZ        : UInt8 = 0x5A
    private static let lowerA        : UInt8 = 0x61
    private static let lowerZ        : UInt8 = 0x7A
    private static let zero          : UInt8 = 0x30
    private static let nine          : UInt8 = 0x39
}
