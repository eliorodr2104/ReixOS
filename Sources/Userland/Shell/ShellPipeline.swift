//
//  ShellPipeline.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import Reix
import ReixABI
import ShellLanguage

struct ShellPipeline {
    private let environment  : Environment
    private let catalog      : ShellCatalog
    private var runtime      = TypedShellRuntime()
    private var arena        = TypedShellSequenceArena()
    private var container    : UInt32 = 0
    private var folder       : UInt32 = 0
    private var lastSequence : ShellSequence?
    private var lastSchema   = ShellTypeSchema.none
    private(set) var outcome: ShellOutcome = .handled

    init(
        environment: Environment,
        catalog    : ShellCatalog = Self.merged()
    ) {
        self.environment = environment
        self.catalog = catalog
    }

    /// Every module the shell was built with, in one catalog.
    ///
    /// This list is the whole of what a shell offers: a module absent here is
    /// absent from resolution, from help and from completion at once.
    static func merged() -> ShellCatalog {
        var catalog = ShellCatalog()
        _ = catalog.merge(CoreModule.self)
        _ = catalog.merge(ProcessModule.self)
        _ = catalog.merge(DiskModule.self)
        _ = catalog.merge(FileSystemModule.self)
        return catalog
    }

    var documentation: ShellCatalog { catalog }

    mutating func execute(
        _ program: TypedShellProgram,
          source : UnsafePointer<UInt8>,
          count  : Int,
          flush  : () -> Bool
    ) -> Result<ShellValue, TypedShellFailure> {
        var evaluator     = runtime
        var sequenceArena = arena
        let result        = catalog.withSignatures { signatures in
            evaluator.execute(program, source: source, count: count, signatures: signatures, arena: &sequenceArena) { invocation in
                self.invoke(invocation, signatures: signatures, flush: flush)
            }
        }
        runtime = evaluator
        arena = sequenceArena
        if case .success(let value) = result {
            lastSequence = runtime.sequence(for: value, in: arena)
        } else {
            lastSequence = nil
        }
        return result
    }

    /// Routes one resolved call to the module that documented it.
    ///
    /// The namespace a command was declared under is the module that answers
    /// it, so nothing here knows a verb by name.
    private mutating func invoke(
        _ invocation: TypedShellInvocation,
          signatures: UnsafeBufferPointer<TypedShellSignature?>,
          flush     : () -> Bool
    ) -> TypedShellInvocationResult {
        guard invocation.signatureIndex >= 0,
              invocation.signatureIndex < signatures.count,
              let descriptor = catalog.command(at: invocation.signatureIndex),
              let receiver = catalog.receiver(ofCommandAt: invocation.signatureIndex)
        else { return .failure(UInt32.max) }

        if same(receiver.name, CoreModule.namespace.name) {
            return dispatch(CoreModule.self, descriptor, invocation, flush)
        }
        if same(receiver.name, ProcessModule.namespace.name) {
            return dispatch(ProcessModule.self, descriptor, invocation, flush)
        }
        if same(receiver.name, DiskModule.namespace.name) {
            return dispatch(DiskModule.self, descriptor, invocation, flush)
        }
        if same(receiver.name, FileSystemModule.namespace.name) {
            return dispatch(FileSystemModule.self, descriptor, invocation, flush)
        }
        return .failure(UInt32.max)
    }

    private mutating func dispatch<Module: ShellModule>(
        _ module     : Module.Type,
        _ descriptor : ShellCommandDescriptor,
        _ invocation : TypedShellInvocation,
        _ flush      : () -> Bool
    ) -> TypedShellInvocationResult {
        if let value = withSession(line: UnsafePointer(Self.empty.utf8Start), count: 0, {
            Module.value(for: descriptor.code, in: &$0)
        }) {
            // What the answer is made of, so printing it can say so.
            if case .sequence = value { lastSchema = descriptor.schema }
            return value
        }

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { storage in
            var cursor = 0
            func append(_ text: StaticString) -> Span? {
                guard text.utf8CodeUnitCount <= storage.count - cursor else { return nil }
                let span = Span(start: cursor, count: text.utf8CodeUnitCount)
                for index in 0..<text.utf8CodeUnitCount { storage[cursor + index] = text.utf8Start[index] }
                cursor += text.utf8CodeUnitCount
                return span
            }
            guard let receiver = append(Module.namespace.name),
                  let verb = append(descriptor.verb)
            else { return .failure(UInt32.max) }
            var command = Command(receiver: receiver, verb: verb)
            for index in 0..<invocation.argumentCount {
                guard let argument = invocation.arguments[index], command.argumentCount < command.arguments.count else {
                    return .failure(UInt32.max)
                }
                let start = cursor
                switch argument.value {
                    case .text(let text):
                        let copied = text.withBytes { bytes, count -> Bool in
                            guard count <= storage.count - cursor else { return false }
                            for offset in 0..<count { storage[cursor + offset] = bytes[offset] }
                            cursor += count
                            return true
                        }
                        guard copied else { return .failure(UInt32.max) }
                    case .number(let number):
                        var value  = number
                        var digits = 1
                        while value >= 10 { value /= 10; digits += 1 }
                        guard digits <= storage.count - cursor else { return .failure(UInt32.max) }
                        value = number
                        var position = cursor + digits
                        while position > cursor {
                            position -= 1
                            storage[position] = UInt8(value % 10) + 0x30
                            value /= 10
                        }
                        cursor += digits
                    default:
                        return .failure(UInt32.max)
                }
                command.arguments[command.argumentCount] = Span(start: start, count: cursor - start)
                command.argumentCount += 1
            }
            guard Module.fill(&command, for: descriptor.code, at: cursor) else {
                return .failure(UInt32.max)
            }

            let result = withSession(line: storage.baseAddress!, count: cursor) { session in
                Module.handleResult(command, in: &session)
            }
            outcome = result.outcome
            guard result.status == .ok else { return .failure(result.status.rawValue) }
            for index in 0..<result.records.count {
                if let record = result.records.record(at: index),
                   record.kind == .fileSystemStatus,
                   record.value0 != UInt64(FSStatus.ok.rawValue) {
                    return .failure(UInt32(truncatingIfNeeded: record.value0))
                }
            }
            guard ShellRenderer.present(result.records), result.frame.map({ ShellRenderer.present($0) }) ?? true else {
                return .failure(UInt32.max)
            }
            guard flush() else { return .failure(UInt32.max) }
            return .success(.void)
        }
    }

    private mutating func withSession<Result>(
          line  : UnsafePointer<UInt8>,
          count : Int,
        _ body: (inout ShellSession) -> Result
    ) -> Result {
        var session = ShellSession(environment: environment, line: line, count: count, catalog: catalog)
        session.container = container
        session.folder = folder
        let result = body(&session)
        container = session.container
        folder = session.folder
        return result
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

    mutating func present(_ value: ShellValue) -> Bool {
        switch value {
            case .void: return true
            case .boolean(let flag):
                print(flag ? "true" : "false")
            case .number(let value):
                printDec(value)
            case .text(let text):
                text.withBytes { printPadded($0, count: $1, width: 0) }
                print("")
            case .record(let object):
                object.name.withBytes { printPadded($0, count: $1, width: 0) }
                print("")
            case .sequence:
                guard let values = lastSequence else { return false }
                for index in 0..<values.count {
                    guard let object = values.value(at: index) else { continue }
                    present(object, as: lastSchema)
                }
        }
        return !ShellOutput.overflowed
    }

    /// One element of an answer, drawn as what it is.
    ///
    /// A container is a place you cross into and wears the `::` that crosses
    /// into it; a folder wears the `/` that walks into it; a file wears
    /// nothing. The colours are roles, so a terminal that has none still gets
    /// the marks.
    private func present(
        _ object: ShellObject,
          as schema: ShellTypeSchema
    ) {
        guard schema.element == .entry else {
            if schema.element == .process {
                ShellOutput.styled(.number) { printDecPadded(object.number0, width: 6) }
                print(" ", terminator: "")
            }
            object.name.withBytes { bytes, count in
                ShellOutput.styled(.plain) { printPadded(bytes, count: count, width: 0) }
            }
            print("")
            return
        }

        let kind = FSKind(rawValue: UInt8(truncatingIfNeeded: object.kind))
        let role : ReixTextSurfaceStyleRole
        let mark : StaticString
        switch kind {
            case .container?: role = .namespace; mark = "::"
            case .folder?   : role = .path;      mark = "/"
            default         : role = .plain;     mark = ""
        }
        print("  ", terminator: "")
        ShellOutput.styled(role) {
            object.name.withBytes { bytes, count in printPadded(bytes, count: count, width: 0) }
            if mark.utf8CodeUnitCount > 0 { print(mark, terminator: "") }
        }
        print("")
    }

    private static let empty: StaticString = ""
}
