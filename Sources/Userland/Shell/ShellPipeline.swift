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
    private enum Service: Int {
        case help, exit, halt
        case processList, processes, spawn
        case diskInfo, diskRead
        case list, currentDirectory, changeDirectory, move
        case free, info, read, write, createDirectory, createFile
        case container, remove, name, unmount, compact, scrub
    }

    private let environment  : Environment
    private var runtime      = TypedShellRuntime()
    private var arena        = TypedShellSequenceArena()
    private var container    : UInt32 = 0
    private var folder       : UInt32 = 0
    private var lastSequence : ShellSequence?
    private(set) var outcome: ShellOutcome = .handled

    init(environment: Environment) {
        self.environment = environment
    }

    mutating func execute(
        _ program: TypedShellProgram,
          source   : UnsafePointer<UInt8>,
          count    : Int
    ) -> Result<ShellValue, TypedShellFailure> {
        var table          = InlineArray<26, TypedShellSignature?>(repeating: nil)
        let signatureCount = Self.signatures(into: &table)
        var evaluator      = runtime
        var sequenceArena  = arena
        let result         = table.span.withUnsafeBufferPointer { all in
            let signatures = UnsafeBufferPointer(start: all.baseAddress!, count: signatureCount)
            return evaluator.execute(program, source: source, count: count, signatures: signatures, arena: &sequenceArena) { invocation in
                self.invoke(invocation, signatures: signatures)
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

    private mutating func invoke(
        _ invocation: TypedShellInvocation,
          signatures  : UnsafeBufferPointer<TypedShellSignature?>
    ) -> TypedShellInvocationResult {
        guard invocation.signatureIndex >= 0,
              invocation.signatureIndex < signatures.count,
              signatures[invocation.signatureIndex] != nil,
              let service = Service(rawValue: invocation.signatureIndex)
        else { return .failure(UInt32.max) }

        if service == .list {
            return withSession(line: UnsafePointer(Self.empty.utf8Start), count: 0) {
                FileSystemModule.listValue(in: &$0)
            }
        }
        if service == .processList || service == .processes {
            return ProcessModule.listValue(authority: environment.profiler)
        }

        let target: (namespace: StaticString, verb: StaticString)
        switch service {
            case .help: target = ("shell", "help")
            case .exit: target = ("shell", "exit")
            case .halt: target = ("shell", "halt")
            case .spawn: target = ("process", "spawn")
            case .diskInfo: target = ("disk", "info")
            case .diskRead: target = ("disk", "read")
            case .currentDirectory: target = ("fs", "where")
            case .changeDirectory: target = ("fs", "move")
            case .move: target = ("fs", "rename")
            case .free: target = ("fs", "free")
            case .info: target = ("fs", "info")
            case .read: target = ("fs", "read")
            case .write: target = ("fs", "write")
            case .createDirectory: target = ("fs", "folder")
            case .createFile: target = ("fs", "write")
            case .container: target = ("fs", "container")
            case .remove: target = ("fs", "remove")
            case .name: target = ("fs", "name")
            case .unmount: target = ("fs", "unmount")
            case .compact: target = ("fs", "compact")
            case .scrub: target = ("fs", "scrub")
            case .list, .processList, .processes: return .failure(UInt32.max)
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
            guard let receiver = append(target.namespace), let verb = append(target.verb) else { return .failure(UInt32.max) }
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
            if service == .createFile {
                guard command.argumentCount < command.arguments.count else { return .failure(UInt32.max) }
                command.arguments[command.argumentCount] = Span(start: cursor, count: 0)
                command.argumentCount += 1
            }

            let result = withSession(line: storage.baseAddress!, count: cursor) { session in
                switch service {
                    case .help, .exit, .halt:
                        return CoreModule.handleResult(command, in: &session)
                    case .processList, .processes, .spawn:
                        return ProcessModule.handleResult(command, in: &session)
                    case .diskInfo, .diskRead:
                        return DiskModule.handleResult(command, in: &session)
                    default:
                        return FileSystemModule.handleResult(command, in: &session)
                }
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
            return .success(.void)
        }
    }

    private mutating func withSession<Result>(
          line  : UnsafePointer<UInt8>,
          count : Int,
        _ body: (inout ShellSession) -> Result
    ) -> Result {
        var session = ShellSession(environment: environment, line: line, count: count)
        session.container = container
        session.folder = folder
        let result = body(&session)
        container = session.container
        folder = session.folder
        return result
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
                    object.name.withBytes { printPadded($0, count: $1, width: 0) }
                    print("")
                }
        }
        return !ShellOutput.overflowed
    }

    private static func signatures(into table: inout InlineArray<26, TypedShellSignature?>) -> Int {
        func parameters(_ values: TypedShellParameter...) -> InlineArray<4, TypedShellParameter?> {
            var result = InlineArray<4, TypedShellParameter?>(repeating: nil)
            for index in values.indices where index < result.count { result[index] = values[index] }
            return result
        }
        func put(
            _ service  : Service,
            _ signature: TypedShellSignature
        ) { table[service.rawValue] = signature }
        put(.help, TypedShellSignature(namespace: "shell", name: "help", effect: .pure))
        put(.exit, TypedShellSignature(namespace: "shell", name: "exit", effect: .session))
        put(.halt, TypedShellSignature(namespace: "shell", name: "halt", effect: .machine))
        put(.processList, TypedShellSignature(namespace: "process", name: "list", result: .sequence, namespaceRequired: true))
        put(.processes, TypedShellSignature(namespace: "process", name: "processes", result: .sequence))
        put(.spawn, TypedShellSignature(namespace: "process", name: "spawn", parameters: parameters(TypedShellParameter("name")), parameterCount: 1))
        put(.diskInfo, TypedShellSignature(namespace: "disk", name: "info", namespaceRequired: true))
        put(.diskRead, TypedShellSignature(namespace: "disk", name: "read", parameters: parameters(TypedShellParameter("sector")), parameterCount: 1, namespaceRequired: true))
        put(.list, TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence))
        put(.currentDirectory, TypedShellSignature(namespace: "fileSystem", name: "currentDirectory", effect: .session))
        put(.changeDirectory, TypedShellSignature(namespace: "fileSystem", name: "changeDir", parameters: parameters(TypedShellParameter("at")), parameterCount: 1, effect: .session))
        put(.move, TypedShellSignature(namespace: "fileSystem", name: "move", parameters: parameters(TypedShellParameter("from"), TypedShellParameter("to")), parameterCount: 2))
        put(.free, TypedShellSignature(namespace: "fileSystem", name: "free"))
        put(.info, TypedShellSignature(namespace: "fileSystem", name: "info", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.read, TypedShellSignature(namespace: "fileSystem", name: "read", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.write, TypedShellSignature(namespace: "fileSystem", name: "write", parameters: parameters(TypedShellParameter("at"), TypedShellParameter("text")), parameterCount: 2))
        put(.createDirectory, TypedShellSignature(namespace: "fileSystem", name: "createDirectory", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.createFile, TypedShellSignature(namespace: "fileSystem", name: "createFile", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.container, TypedShellSignature(namespace: "fileSystem", name: "createContainer", parameters: parameters(TypedShellParameter("name"), TypedShellParameter("blocks")), parameterCount: 2))
        put(.remove, TypedShellSignature(namespace: "fileSystem", name: "remove", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.name, TypedShellSignature(namespace: "fileSystem", name: "name", parameters: parameters(TypedShellParameter("name")), parameterCount: 1))
        put(.unmount, TypedShellSignature(namespace: "fileSystem", name: "unmount"))
        put(.compact, TypedShellSignature(namespace: "fileSystem", name: "compact", parameters: parameters(TypedShellParameter("at")), parameterCount: 1))
        put(.scrub, TypedShellSignature(namespace: "fileSystem", name: "scrub"))
        return Service.scrub.rawValue + 1
    }

    private static let empty: StaticString = ""
}
