//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Foundation
import ReixABI
import ShellLanguage
import ShellBenchmarkSupport
import TerminalTestSupport

private let parser64Source = Array(("let value = \"" + String(repeating: "x", count: 64) + "\"").utf8)
private func parse64() -> Int {
    parser64Source.withUnsafeBufferPointer {
        guard case .success(let program) = TypedShellParser.parse($0.baseAddress!, count: $0.count) else { return 0 }
        return program.count
    }
}

private let editorSeedChunk = [UInt8](repeating: UInt8(ascii: "x"), count: ReixInputProtocol.maximumPayload)
private func seedEditor(
    _ editor: inout ShellLineEditor,
      count : Int = 100
) -> UInt32? {
    var written  = 0
    var sequence : UInt32 = 1
    while written < count {
        let amount = min(editorSeedChunk.count, count - written)
        let update = editorSeedChunk.withUnsafeBufferPointer {
            editor.apply(ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0.baseAddress!, count: amount)!)
        }
        guard update.requiresPresentation else { return nil }
        written += amount
        sequence += 1
    }
    return editor.count == count && editor.cursor == count ? sequence : nil
}

private let complexSource = Array(
    (
        "let folders = list.filter { $0.isFolder }, "
            + "folders.filter { !$0.name.contains(\"1\") }.sorted { $0.name < $1.name }"
    ).utf8
)
private let complexProgram : TypedShellProgram = complexSource.withUnsafeBufferPointer {
    guard case .success(let program) = TypedShellParser.parse($0.baseAddress!, count: $0.count) else {
        fatalError("ShellBench preflight: complex parser fixture was refused")
    }
    return program
}
private let zetaFolder     = ShellObject(kind: UInt16(FSKind.folder.rawValue), name: ShellText("zeta")!)
private let alphaFolder    = ShellObject(kind: UInt16(FSKind.folder.rawValue), name: ShellText("alpha")!)
private var listSignatures = InlineArray<1, TypedShellSignature?>(repeating: nil)
private enum EvaluatorPreflightError: Error {
    case runtime(TypedShellFailure)
    case notSequence(ShellValue)
    case wrongCount(Int)
}
private let evaluatorPreflight: Result<Void, EvaluatorPreflightError> = {
    listSignatures[0] = TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence)
    var runtime = TypedShellRuntime()
    var arena   = TypedShellSequenceArena()
    func execute() -> Result<Int, EvaluatorPreflightError> {
        complexSource.withUnsafeBufferPointer { bytes in
            let result = runtime.execute(
                complexProgram,
                source: bytes.baseAddress!,
                count: bytes.count,
                signatures: listSignatures.span.withUnsafeBufferPointer { $0 },
                arena: &arena
            ) { invocation in
                guard invocation.signatureIndex == 0 else { return .failure(1) }
                var sequence = ShellSequence()
                sequence.beginBatch()
                _ = sequence.append(zetaFolder)
                _ = sequence.append(alphaFolder)
                return .sequence(sequence)
            }
            guard case .success(let value) = result else {
                if case .failure(let failure) = result { return .failure(.runtime(failure)) }
                fatalError("unreachable evaluator result")
            }
            guard let sequence = runtime.sequence(for: value, in: arena) else {
                return .failure(.notSequence(value))
            }
            return .success(sequence.count)
        }
    }
    guard case .success(let first) = execute() else { return execute().map { _ in () } }
    guard case .success(let second) = execute() else { return execute().map { _ in () } }
    return first == 2 && second == 2 ? .success(()) : .failure(.wrongCount(first))
}()

private let sequenceSource = Array(
    "list.filter { $0.isFolder }.map { $0 }.flatMap { list }.sorted { $0.name < $1.name }".utf8
)
private let sequenceProgram : TypedShellProgram = sequenceSource.withUnsafeBufferPointer {
    guard case .success(let program) = TypedShellParser.parse($0.baseAddress!, count: $0.count) else {
        fatalError("ShellBench preflight: sequence fixture was refused")
    }
    return program
}
private let sequencePreflight: String? = {
    var runtime = TypedShellRuntime()
    var arena   = TypedShellSequenceArena()
    let result  = sequenceSource.withUnsafeBufferPointer { bytes in
        runtime.execute(
            sequenceProgram,
            source: bytes.baseAddress!,
            count: bytes.count,
            signatures: listSignatures.span.withUnsafeBufferPointer { $0 },
            arena: &arena
        ) { invocation in
            guard invocation.signatureIndex == 0 else { return .failure(1) }
            var sequence = ShellSequence()
            sequence.beginBatch()
            _ = sequence.append(zetaFolder)
            _ = sequence.append(alphaFolder)
            return .sequence(sequence)
        }
    }
    guard case .success(let value) = result else {
        if case .failure(let failure) = result { return "failure=\(failure)" }
        return "unexpected result"
    }
    guard let sequence = runtime.sequence(for: value, in: arena) else {
        return "value=\(value) sequence=unavailable"
    }
    let names = (0..<sequence.count).map {
        guard let name = sequence.value(at: $0)?.name else { return "nil" }
        if name.equals("alpha") { return "alpha" }
        if name.equals("zeta") { return "zeta" }
        return "other"
    }.joined(separator: ",")
    guard sequence.count == 4 else { return "count=\(sequence.count) names=\(names)" }
    guard sequence.value(at: 0)?.name.equals("alpha") == true
        && sequence.value(at: 1)?.name.equals("alpha") == true
        && sequence.value(at: 2)?.name.equals("zeta") == true
        && sequence.value(at: 3)?.name.equals("zeta") == true else { return "order=\(names)" }
    return nil
}()

private func editor(
    _ position: Int,
      deleting: Bool,
      size: Int = 100
) -> Int {
    var value = ShellLineEditor()
    guard position >= 0,
          position <= size,
          var sequence = seedEditor(&value, count: size)
    else { return 0 }
    for _ in 0..<(size - position) {
        _ = value.apply(ReixInputRecord(kind: .left, sequence: sequence)!)
        sequence += 1
    }
    if deleting {
        let update = value.apply(ReixInputRecord(kind: .delete, sequence: sequence)!)
        return update.requiresPresentation && value.count == size - 1 ? value.count : 0
    }
    var byte = UInt8(ascii: "z")
    return withUnsafePointer(to: &byte) { pointer in
        let update = value.apply(
            ReixInputRecord(kind: .insert, sequence: sequence, bytes: pointer, count: 1)!
        )
        return update.requiresPresentation && value.count == size + 1 ? value.count : 0
    }
}

guard case .success(let configuration) = BenchmarkConfiguration.parse(
    Array(CommandLine.arguments.dropFirst())
) else {
    fputs(BenchmarkConfiguration.usage + "\n", stderr)
    exit(64)
}
var results: [BenchmarkResult] = []
func add(
    _ name: String,
    _ work: String,
    _ body: @escaping () -> Int
) {
    results.append(
        ShellBenchmark.measure(name: name, workload: work, configuration: configuration, body: body)
    )
}
func unsupported(
    _ name  : String,
    _ size  : Int,
    _ limit : Int,
    _ reason: String
) { results.append(.unsupported(name, requested: size, limit: limit, reason: reason)) }

guard case .success = evaluatorPreflight else {
    if case .failure(let error) = evaluatorPreflight { fatalError("ShellBench preflight: \(error)") }
    fatalError("ShellBench preflight failed")
}
guard sequencePreflight == nil else {
    fatalError("ShellBench preflight: sequence filter/map/flatMap/sorted \(sequencePreflight!)")
}
for position in [0, 50, 100] {
    guard editor(position, deleting: false) == 101 else {
        fatalError("ShellBench preflight: insert position \(position)")
    }
}
for position in [0, 50, 99] {
    guard editor(position, deleting: true) == 99 else {
        fatalError("ShellBench preflight: delete position \(position)")
    }
}
guard parse64() > 0 else { fatalError("ShellBench preflight: parser64") }

add("parser/desugaring", "legacy parser/desugaring") {
    complexSource.withUnsafeBufferPointer {
        guard case .success(let program) = TypedShellParser.parse($0.baseAddress!, count: $0.count) else { return 0 }
        return program.count
    }
}

var evaluatorRuntime = TypedShellRuntime()
var evaluatorArena   = TypedShellSequenceArena()
add("resolver/evaluator", "legacy resolver/evaluator") {
    complexSource.withUnsafeBufferPointer { bytes in
        let result = evaluatorRuntime.execute(
            complexProgram,
            source: bytes.baseAddress!,
            count: bytes.count,
            signatures: listSignatures.span.withUnsafeBufferPointer { $0 },
            arena: &evaluatorArena
        ) { invocation in
            guard invocation.signatureIndex == 0 else { return .failure(1) }
            var sequence = ShellSequence()
            sequence.beginBatch()
            _ = sequence.append(zetaFolder)
            _ = sequence.append(alphaFolder)
            return .sequence(sequence)
        }
        guard case .success(let value) = result,
              let sequence = evaluatorRuntime.sequence(for: value, in: evaluatorArena)
        else { return 0 }
        return sequence.count
    }
}

var protocolEditor       = ShellLineEditor()
let protocolPayload      = [UInt8(ascii: "x")]
var protocolEventStorage = [UInt8](repeating: 0, count: ReixInputProtocol.recordBytes)
var protocolPatchStorage = [UInt8](repeating: 0, count: ReixTextSurfaceProtocol.recordBytes)
var protocolMetadata     = [UInt8](repeating: 0, count: ReixTextSurfaceFrameDescriptor.wireBytes)
add("protocol/editor", "typed frame protocol/editor") {
    let encodedEvent = protocolPayload.withUnsafeBufferPointer { payload in
        protocolEventStorage.withUnsafeMutableBufferPointer {
            ReixInputRecord(
                kind    : .insert,
                sequence: 77,
                bytes   : payload.baseAddress!,
                count   : payload.count
            )!.encode(into: $0.baseAddress!, capacity: $0.count)
        }
    }
    guard encodedEvent else { return 0 }
    let event = protocolEventStorage.withUnsafeBufferPointer {
        ReixInputRecord.decode($0.baseAddress!, length: ReixInputProtocol.recordBytes)
    }
    guard let event else { return 0 }
    protocolEditor.reset()
    guard protocolEditor.withFrame({ _ in true }) else { return 0 }
    let update = protocolEditor.apply(event)
    guard update.requiresPresentation else { return 0 }
    var editorFrame: ShellEditorFrame?
    guard protocolEditor.withFrame({ editorFrame = $0.frame; return true }),
          let patch = editorFrame
    else { return 0 }
    guard let descriptor = ReixTextSurfaceFrameDescriptor(
        kind: patch.kind,
        correlation: patch.correlation,
        revision: 2,
        baseRevision: 1,
        patchOffset: patch.patchOffset,
        replacedLength: patch.replacedLength,
        textLength: patch.textLength,
        columns: patch.columns,
        rows: patch.rows,
        cursorRow: patch.cursorRow,
        cursorColumn: patch.cursorColumn,
        viewportRow: patch.viewportRow,
        viewportRows: patch.viewportRows
    ) else { return 0 }
    let encodedMetadata = protocolMetadata.withUnsafeMutableBufferPointer {
        descriptor.encode(into: $0.baseAddress!, capacity: $0.count)
    }
    guard encodedMetadata else { return 0 }
    let record = protocolMetadata.withUnsafeBufferPointer {
        ReixTextSurfaceFrameRecord(
            kind: .begin,
            transaction: 1,
            chunk: 0,
            chunks: 3,
            checksum: 1,
            bytes: $0.baseAddress!,
            count: $0.count
        )!
    }
    let encodedPatch = protocolPatchStorage.withUnsafeMutableBufferPointer {
        record.encode(into: $0.baseAddress!, capacity: $0.count)
    }
    guard encodedPatch else { return 0 }
    let decodedPatch = protocolPatchStorage.withUnsafeBufferPointer {
        ReixTextSurfaceFrameRecord.decode($0.baseAddress!, length: ReixTextSurfaceProtocol.recordBytes)
    }
    guard decodedPatch?.transaction == 1 else { return 0 }
    return ReixInputProtocol.recordBytes + ReixTextSurfaceProtocol.recordBytes + Int(descriptor.correlation)
}
for entry in [("editor/insert-start", 0), ("editor/insert-center", 50), ("editor/insert-end", 100)] {
    add(entry.0, "editor seed, position and insert") { editor(entry.1, deleting: false) }
}
for entry in [("editor/delete-start", 0), ("editor/delete-center", 50), ("editor/delete-end", 99)] {
    add(entry.0, "editor seed, position and delete") { editor(entry.1, deleting: true) }
}
for size in [1, 64, 256, 2048, 8192] {
    add("editor/insert-end/\(size)", "bounded editor insertion at resulting size") {
        editor(size - 1, deleting: false, size: size - 1)
    }
}
for size in [64, 256, 2048, 8192] {
    add("editor/delete-end/\(size)", "bounded editor deletion at starting size") {
        editor(size - 1, deleting: true, size: size)
    }
}
for size in [1, 256, 1024, 8192] {
    add("paste/\(size)", "atomic bracketed paste") {
        var editor = ShellLineEditor()
        _ = editor.apply(ReixInputRecord(kind: .pasteBegin, sequence: 1)!)
        var written = 0
        var sequence: UInt32 = 2
        while written < size {
            let amount = min(editorSeedChunk.count, size - written)
            let update = editorSeedChunk.withUnsafeBufferPointer {
                editor.apply(
                    ReixInputRecord(
                        kind: .pasteChunk,
                        sequence: sequence,
                        bytes: $0.baseAddress!,
                        count: amount
                    )!
                )
            }
            guard !update.requiresPresentation else { return 0 }
            written += amount
            sequence += 1
        }
        let committed = editor.apply(ReixInputRecord(kind: .pasteEnd, sequence: sequence)!)
        return committed.requiresPresentation && editor.count == size ? size : 0
    }
}
add("parser/64", "prebuilt parser fixture") { parse64() }
for size in [256, 1024, 8192] {
    let source = Array(("let value = \"" + String(repeating: "x", count: size - 14) + "\"").utf8)
    add("parser/\(size)", "bounded typed parser source") {
        source.withUnsafeBufferPointer {
            guard case .success(let program) = TypedShellParser.parse(
                $0.baseAddress!,
                count: $0.count
            ) else { return 0 }
            return program.count + source.count
        }
    }
}
for entry in [(80, 24), (120, 40), (240, 80)] {
    add("layout/\(entry.0)x\(entry.1)", "terminal replay") {
        var screen = TerminalScreenModel(columns: entry.0, rows: entry.1)
        try! screen.feed("reix> hello\r\nreix> world")
        return screen.cursorRow
    }
}
var editorLayout = ShellLineEditor()
guard var editorLayoutSequence = seedEditor(&editorLayout, count: ShellLineEditor.capacity) else {
    fatalError("ShellBench preflight: editor layout seed")
}
var editorLayoutRows: UInt16 = 24
add("editor/layout-8192/80x24", "bounded Unicode editor layout") {
    editorLayoutRows = editorLayoutRows == 24 ? 25 : 24
    let resized = editorLayout.apply(
        ReixInputRecord(
            kind: .resize,
            sequence: editorLayoutSequence,
            width: 80,
            height: editorLayoutRows
        )!
    )
    editorLayoutSequence &+= 1
    guard resized.requiresPresentation else { return 0 }
    var result = 0
    guard editorLayout.withFrame({ source in
        result = Int(source.frame.cursorRow) + Int(source.frame.cursorColumn) + 1
        return true
    }) else { return 0 }
    return result
}
add("terminal/full-replace", "current full replacement") { editor(100, deleting: false) }
add("terminal/small-delta", "current delta") { editor(99, deleting: true) }
var sequenceRuntime = TypedShellRuntime()
var sequenceArena   = TypedShellSequenceArena()
add("sequence/filter-map-flatMap-sort", "filter, map, flatMap and sorted sequence") {
    sequenceSource.withUnsafeBufferPointer { bytes in
        let result = sequenceRuntime.execute(
            sequenceProgram,
            source: bytes.baseAddress!,
            count: bytes.count,
            signatures: listSignatures.span.withUnsafeBufferPointer { $0 },
            arena: &sequenceArena
        ) { invocation in
            guard invocation.signatureIndex == 0 else { return .failure(1) }
            var sequence = ShellSequence()
            sequence.beginBatch()
            _ = sequence.append(zetaFolder)
            _ = sequence.append(alphaFolder)
            return .sequence(sequence)
        }
        guard case .success(let value) = result,
              let sequence = sequenceRuntime.sequence(for: value, in: sequenceArena)
        else { return 0 }
        return sequence.count
    }
}
unsupported("sequence/256", 256, 64, "current ShellSequence capacity")

if configuration.json {
    switch ShellBenchmark.json(
        results,
        configuration: configuration,
        environment: ProcessInfo.processInfo.environment
    ) {
        case .success(let value):
            print(value)
        case .failure(let error):
            fputs("ShellBench JSON error: \(error)\n", stderr)
            exit(1)
    }
} else {
    for result in results {
        if let stats = result.statistics {
            print(
                "\(result.name): status=measured p50=\(stats.p50) ns/op "
                    + "p95=\(stats.p95) ns/op p99=\(stats.p99) ns/op checksum=\(result.checksum)"
            )
        } else {
            print(
                "\(result.name): status=unsupported requested=\(result.requestedSize!) "
                    + "limit=\(result.supportedLimit!) reason=\(result.reason!)"
            )
        }
    }
}
