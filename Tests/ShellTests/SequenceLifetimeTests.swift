import Foundation
import Testing
import ReixABI
import ShellLanguage

private final class SequenceLifetimeProbe: @unchecked Sendable {
    var passed = false
}

@Suite("Closure sequence lifetimes")
struct SequenceLifetimeTests {
    @Test("nested predicates release temporary sequences on every iteration")
    func nestedPredicates() {
        for script in [
            "list.filter { list.contains { true } }",
            "list.allSatisfy { list.contains { true } }",
            "list.contains { list.allSatisfy { false } }"
        ] {
            let probe = SequenceLifetimeProbe()
            let worker = Thread {
                var runtime = TypedShellRuntime()
                var arena = TypedShellSequenceArena()
                var signatures = InlineArray<1, TypedShellSignature?>(repeating: nil)
                signatures[0] = TypedShellSignature(namespace: "fileSystem", name: "list", result: .sequence)
                var records = ShellSequence()
                for _ in 0..<32 { _ = records.append(ShellObject(kind: 1, name: ShellText("entry")!)) }
                Array(script.utf8).withUnsafeBufferPointer { bytes in
                    guard case .success(let program) = TypedShellParser.parse(bytes.baseAddress!, count: bytes.count) else { return }
                    let result = signatures.span.withUnsafeBufferPointer { table in
                        runtime.execute(program, source: bytes.baseAddress!, count: bytes.count,
                                        signatures: table, arena: &arena) { _ in .sequence(records) }
                    }
                    switch result {
                        case .success(let value):
                            if script.contains("filter") {
                                probe.passed = runtime.sequence(for: value, in: arena)?.count == 32
                            } else {
                                probe.passed = value == .boolean(!script.contains("false"))
                            }
                        case .failure: break
                    }
                }
            }
            worker.stackSize = 8 * 1024 * 1024
            worker.start()
            while !worker.isFinished { Thread.sleep(forTimeInterval: 0.001) }
            #expect(probe.passed, "\(script)")
        }
    }
}
