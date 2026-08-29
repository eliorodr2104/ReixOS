//
//  TerminalStructuredProtocolTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/08/2026.
//

import Testing
import Foundation
import ReixABI

@Suite("Structured terminal input and patches")
struct TerminalStructuredProtocolTests {
    @Test("terminal input accepts only the matching request sequence")
    func terminalReadInputSequenceFencePolicy() throws {
        let root   = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Reix/Console/Terminal.swift"), encoding: .utf8)
        let method = try #require(source.components(separatedBy: "public mutating func readInput() -> TerminalInputEvent? {").dropFirst().first?.components(separatedBy: "    /// Writes `prompt`").first)
        #expect(method.contains("guard let event = TerminalInputEvent.decode"))
        #expect(method.contains("current != 0, event.sequence == current"))
        #expect(method.contains("return event"))
    }

    @Test("every semantic input kind round trips and malformed records fail closed")
    func inputEvents() {
        let kinds: [TerminalInputKind] = [
            .left, .right, .up, .down, .home, .end, .backspace, .delete,
            .enter, .cancel, .eof, .historyPrevious, .historyNext,
            .ignored,
        ]
        var storage = [UInt8](repeating: 0, count: 64)
        for kind in kinds {
            let event = TerminalInputEvent(kind: kind, sequence: 42)
            let length = storage.withUnsafeMutableBufferPointer {
                event.encode(into: $0.baseAddress!, capacity: $0.count)
            }
            storage.withUnsafeBufferPointer {
                #expect(TerminalInputEvent.decode($0.baseAddress!, length: length) == event)
            }
        }
        let resized = TerminalInputEvent(kind: .resize, sequence: 43, width: 120, height: 40)
        let resizedLength = storage.withUnsafeMutableBufferPointer {
            resized.encode(into: $0.baseAddress!, capacity: $0.count)
        }
        storage.withUnsafeBufferPointer {
            #expect(TerminalInputEvent.decode($0.baseAddress!, length: resizedLength) == resized)
        }
        storage[14] = 1
        storage.withUnsafeBufferPointer {
            #expect(TerminalInputEvent.decode($0.baseAddress!, length: resizedLength) == nil)
        }

        var malformed = UInt8(0xC3)
        let invalidInsert = withUnsafePointer(to: &malformed) {
            TerminalInputEvent(sequence: 44, bytes: $0, count: 1)
        }
        let invalidLength = storage.withUnsafeMutableBufferPointer {
            invalidInsert.encode(into: $0.baseAddress!, capacity: $0.count)
        }
        #expect(invalidLength == 0)

        var ascii = UInt8(ascii: "x")
        let validInsert = withUnsafePointer(to: &ascii) {
            TerminalInputEvent(sequence: 45, bytes: $0, count: 1)
        }
        let insertLength = storage.withUnsafeMutableBufferPointer {
            validInsert.encode(into: $0.baseAddress!, capacity: $0.count)
        }
        storage[TerminalInputEvent.headerBytes] = 0xC3
        storage.withUnsafeBufferPointer {
            #expect(TerminalInputEvent.decode($0.baseAddress!, length: insertLength) == nil)
        }
    }

    @Test("render patches carry presentation state but no language objects")
    func patches() {
        let text = Array("hello".utf8)
        var storage = [UInt8](repeating: 0, count: 300)
        let patch = text.withUnsafeBufferPointer {
            TerminalRenderPatch(
                kind: .replaceBuffer,
                sequence: 7,
                bytes: $0.baseAddress!,
                count: $0.count,
                previousRows: 2,
                previousCursorRow: 1,
                cursorRow: 0,
                cursorColumn: 3
            )
        }
        let length = storage.withUnsafeMutableBufferPointer {
            patch.encode(into: $0.baseAddress!, capacity: $0.count)
        }
        storage.withUnsafeBufferPointer {
            #expect(TerminalRenderPatch.decode($0.baseAddress!, length: length) == patch)
        }
        storage[20] = 1
        storage.withUnsafeBufferPointer {
            #expect(TerminalRenderPatch.decode($0.baseAddress!, length: length) == nil)
        }
        storage[20] = 0
        storage[14] = 2
        storage.withUnsafeBufferPointer {
            #expect(TerminalRenderPatch.decode($0.baseAddress!, length: length) == nil)
        }
    }
}
