//
//  TerminalStructuredProtocolTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/08/2026.
//

import Testing
import Foundation
import ReixABI

@Suite("InputServer and TextSurface records")
struct TerminalStructuredProtocolTests {
    @Test("every semantic input kind uses the exact thirty-two byte wire record")
    func inputRecords() {
        let kinds: [ReixInputKind] = [.left, .right, .up, .down, .home, .end, .backspace, .delete, .enter, .cancel, .eof, .historyPrevious, .historyNext, .ignored, .pasteBegin, .pasteEnd]
        var storage = [UInt8](repeating: 0, count: ReixInputProtocol.recordBytes)
        for kind in kinds {
            let event = ReixInputRecord(kind: kind, modifiers: [.shift], sequence: 42)!
            #expect(storage.withUnsafeMutableBufferPointer { event.encode(into: $0.baseAddress!, capacity: $0.count) })
            #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == event)
        }
        let resize = ReixInputRecord(kind: .resize, sequence: 43, width: 120, height: 40)!
        #expect(storage.withUnsafeMutableBufferPointer { resize.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == resize)
        #expect(MemoryLayout<ReixInputRecord>.size >= ReixInputProtocol.recordBytes)
    }

    @Test("input records fail closed on wire length, bits, zero sequence and malformed UTF-8")
    func inputFailures() {
        var storage = [UInt8](repeating: 0, count: ReixInputProtocol.recordBytes)
        var byte = UInt8(ascii: "x")
        let record = withUnsafePointer(to: &byte) { ReixInputRecord(kind: .insert, sequence: 1, bytes: $0, count: 1)! }
        #expect(storage.withUnsafeMutableBufferPointer { record.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count - 1) } == nil)
        storage[4] = 0x80
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == nil)
        storage[4] = 0
        storage[8] = 0
        storage[9] = 0
        storage[10] = 0
        storage[11] = 0
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == nil)
        let malformed: [[UInt8]] = [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]]
        for bytes in malformed {
            bytes.withUnsafeBufferPointer { #expect(ReixInputRecord(kind: .insert, sequence: 1, bytes: $0.baseAddress!, count: $0.count) == nil) }
        }
    }

    @Test("TextSurface commands use the exact two-hundred-eighty-eight byte record")
    func surfaceCommands() {
        var storage = [UInt8](repeating: 0, count: ReixTextSurfaceProtocol.recordBytes)
        let text = Array("hello".utf8)
        let command = text.withUnsafeBufferPointer {
            ReixTextSurfaceCommand(kind: .replaceBuffer, sequence: 7, bytes: $0.baseAddress!, count: $0.count, previousRows: 2, previousCursorRow: 1, cursorRow: 0, cursorColumn: 3)!
        }
        #expect(storage.withUnsafeMutableBufferPointer { command.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(storage.withUnsafeBufferPointer { ReixTextSurfaceCommand.decode($0.baseAddress!, length: $0.count) } == command)
        storage[24] = 1
        #expect(storage.withUnsafeBufferPointer { ReixTextSurfaceCommand.decode($0.baseAddress!, length: $0.count) } == nil)
    }

    @Test("the client consumes only a matching typed input record")
    func terminalReadInputSequenceFencePolicy() throws {
        let root   = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Reix/Console/Terminal.swift"), encoding: .utf8)
        let method = try #require(source.components(separatedBy: "public mutating func readInput() -> ReixInputRecord? {").dropFirst().first?.components(separatedBy: "    public mutating func present").first)
        #expect(method.contains("ring.popInput(sequence: current)"))
        #expect(method.contains("usable = false"))
        let server = try String(contentsOf: root.appending(path: "Sources/Userland/TerminalServer/TerminalServer.swift"), encoding: .utf8)
        #expect(server.contains("ReixTerminalTransport.isCorrelatedSequence(command.sequence)"))
    }

    @Test("terminal sequence domains wrap without crossing")
    func sequenceDomainsWrap() {
        #expect(ReixTerminalTransport.nextCorrelatedSequence(after: 0) == 1)
        #expect(ReixTerminalTransport.nextCorrelatedSequence(after: ReixTerminalTransport.maximumCorrelatedSequence) == 1)
        #expect(ReixTerminalTransport.nextAsynchronousSequence(after: 0) == ReixTerminalTransport.asynchronousSequenceBit)
        #expect(ReixTerminalTransport.nextAsynchronousSequence(after: UInt32.max) == ReixTerminalTransport.asynchronousSequenceBit)
        #expect(ReixTerminalTransport.isCorrelatedSequence(ReixTerminalTransport.maximumCorrelatedSequence))
        #expect(!ReixTerminalTransport.isCorrelatedSequence(ReixTerminalTransport.asynchronousSequenceBit))
    }
}
