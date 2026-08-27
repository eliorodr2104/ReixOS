//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import Foundation
import ReixABI
import ShellLanguage

private let samples = 2_000
private let warmup  = 200

private func percentile(
    _ values  : [UInt64],
    _ fraction: Double
) -> UInt64 {
    let ordered = values.sorted()
    return ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * fraction))]
}

private func measure(
    _ name: String,
    _ body: () -> Int
) {
    var checksum = 0
    for _ in 0..<warmup { checksum &+= body() }
    var times = [UInt64]()
    times.reserveCapacity(samples)
    for _ in 0..<samples {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum &+= body()
        times.append(DispatchTime.now().uptimeNanoseconds - start)
    }
    let total      = times.reduce(0, +)
    let throughput = Double(samples) * 1_000_000_000 / Double(total)
    print("\(name): N=\(samples), warmup=\(warmup), p50=\(percentile(times, 0.50)) ns, p95=\(percentile(times, 0.95)) ns, throughput=\(Int(throughput))/s, checksum=\(checksum)")
}

private func parsed(_ source: String) -> TypedShellProgram {
    source.utf8.withContiguousStorageIfAvailable {
        try! TypedShellParser.parse($0.baseAddress!, count: $0.count).get()
    }!
}

private func verifyRuntimeSemantics() {
    var empty = InlineArray<4, TypedShellParameter?>(repeating: nil)
    empty[0] = TypedShellParameter("from")
    empty[1] = TypedShellParameter("to")
    var signatures = InlineArray<5, TypedShellSignature?>(repeating: nil)
    signatures[0] = TypedShellSignature(namespace: "test", name: "ok", result: .number)
    signatures[1] = TypedShellSignature(namespace: "test", name: "fail", result: .number)
    signatures[2] = TypedShellSignature(namespace: "fileSystem", name: "move", parameters: empty, parameterCount: 2)
    signatures[3] = TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence)
    var changeParameters = InlineArray<4, TypedShellParameter?>(repeating: nil)
    changeParameters[0] = TypedShellParameter("at")
    signatures[4] = TypedShellSignature(
        namespace     : "fileSystem",
        name          : "changeDir",
        parameters    : changeParameters,
        parameterCount: 1,
        effect        : .session
    )

    func run(
        _ source: String,
          runtime : inout TypedShellRuntime,
          arena   : inout TypedShellSequenceArena,
          calls   : inout Int
    ) -> Result<ShellValue, TypedShellFailure> {
        let program = parsed(source)
        return Array(source.utf8).withUnsafeBufferPointer { bytes in
            signatures.span.withUnsafeBufferPointer { table in
                runtime.execute(program, source: bytes.baseAddress!, count: bytes.count, signatures: table, arena: &arena) { invocation in
                    calls += 1
                    switch invocation.signatureIndex {
                        case 0: return .success(.number(42))
                        case 1: return .failure(99)
                        case 2: return .success(invocation.arguments[1]!.value)
                        case 3:
                            var sequence = ShellSequence()
                            sequence.beginBatch()
                            _ = sequence.append(ShellObject(kind: UInt16(FSKind.folder.rawValue), name: ShellText("zeta")!))
                            _ = sequence.append(ShellObject(kind: UInt16(FSKind.file.rawValue), name: ShellText("alpha")!))
                            return .sequence(sequence)
                        case 4: return .success(invocation.arguments[0]!.value)
                        default: return .failure(UInt32.max)
                    }
                }
            }
        }
    }

    var runtime = TypedShellRuntime()
    var arena   = TypedShellSequenceArena()
    var calls   = 0
    let stopped = run("let left = ok, fail, ok", runtime: &runtime, arena: &arena, calls: &calls)
    precondition(stopped == .failure(.service(99)) && calls == 2, "comma sequence did not fail fast")

    let binding = run("let answer = ok, answer.toString()", runtime: &runtime, arena: &arena, calls: &calls)
    precondition(binding == .success(.text(ShellText("42")!)), "binding was not visible to the right-hand statement")

    var moves = InlineArray<3, ShellValue?>(repeating: nil)
    let forms = [
        "move from draft to archive",
        "move draft archive",
        "let draft = \"draft\", let archive = \"archive\", fileSystem.move(from: draft, to: archive)",
    ]
    for index in forms.indices {
        let value = run(forms[index], runtime: &runtime, arena: &arena, calls: &calls)
        guard case .success(let result) = value else { preconditionFailure("move form did not evaluate") }
        moves[index] = result
    }
    precondition(moves[0] == moves[1] && moves[1] == moves[2], "compact and canonical move forms differed")

    let compactChange   = run("changeDir archive", runtime: &runtime, arena: &arena, calls: &calls)
    let canonicalChange = run(
        "let destination = \"archive\", fileSystem.changeDir(at: destination)",
        runtime: &runtime,
        arena: &arena,
        calls: &calls
    )
    precondition(compactChange == canonicalChange, "compact and canonical changeDir forms differed")

    let transformed = run(
        "list.map { $0.name }.compactMap { $0 }.flatMap { list }",
        runtime: &runtime,
        arena: &arena,
        calls: &calls
    )
    guard case .success(let transformedValue) = transformed,
          runtime.sequence(for: transformedValue, in: arena)?.count == 4
    else { preconditionFailure("collection chain did not execute") }

    let listProgram = parsed("list")
    let listBytes   = Array("list".utf8)
    for _ in 0..<20 {
        let result = listBytes.withUnsafeBufferPointer { bytes in
            signatures.span.withUnsafeBufferPointer { table in
                runtime.execute(listProgram, source: bytes.baseAddress!, count: bytes.count, signatures: table, arena: &arena) { _ in
                    var sequence = ShellSequence()
                    sequence.beginBatch()
                    _ = sequence.append(ShellObject(kind: 0, name: ShellText("one")!))
                    return .sequence(sequence)
                }
            }
        }
        guard case .success = result else { preconditionFailure("per-command sequence compaction exhausted the arena") }
    }
}

verifyRuntimeSemantics()

private let programText  = "let folders = list.filter { $0.isFolder }, folders.filter { !$0.name.contains(\"1\") }.sorted { $0.name < $1.name }"
private let programBytes = Array(programText.utf8)

measure("parser/desugaring") {
    programBytes.withUnsafeBufferPointer {
        guard case .success(let program) = TypedShellParser.parse($0.baseAddress!, count: $0.count) else { return 0 }
        return program.count
    }
}

var parameters = InlineArray<1, TypedShellSignature?>(repeating: nil)
parameters[0] = TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence)
let parsed = programBytes.withUnsafeBufferPointer {
    try! TypedShellParser.parse($0.baseAddress!, count: $0.count).get()
}
measure("resolver/evaluator") {
    var runtime = TypedShellRuntime()
    var arena   = TypedShellSequenceArena()
    return programBytes.withUnsafeBufferPointer { source in
        parameters.span.withUnsafeBufferPointer { signatures in
            let result = runtime.execute(parsed, source: source.baseAddress!, count: source.count, signatures: signatures, arena: &arena) { _ in
                var sequence = ShellSequence()
                sequence.beginBatch()
                _ = sequence.append(ShellObject(kind: UInt16(FSKind.folder.rawValue), name: ShellText("zeta")!))
                _ = sequence.append(ShellObject(kind: UInt16(FSKind.folder.rawValue), name: ShellText("alpha")!))
                return .sequence(sequence)
            }
            guard case .success(let value) = result, let values = runtime.sequence(for: value, in: arena) else { return 0 }
            return values.count
        }
    }
}

var eventBytes = [UInt8](repeating: 0, count: 64)
var inserted   = UInt8(ascii: "x")
let event      = withUnsafePointer(to: &inserted) { TerminalInputEvent(sequence: 1, bytes: $0, count: 1) }
measure("protocol/editor") {
    var editor = ShellLineEditor()
    return eventBytes.withUnsafeMutableBufferPointer { storage in
        let length = event.encode(into: storage.baseAddress!, capacity: storage.count)
        guard let decoded = TerminalInputEvent.decode(storage.baseAddress!, length: length) else { return 0 }
        _ = editor.apply(decoded)
        guard let patch = editor.apply(TerminalInputEvent(kind: .backspace, sequence: 2)).patch else { return 0 }
        let patchLength = patch.encode(into: storage.baseAddress!, capacity: storage.count)
        return TerminalRenderPatch.decode(storage.baseAddress!, length: patchLength)?.sequence == patch.sequence ? patchLength : 0
    }
}
