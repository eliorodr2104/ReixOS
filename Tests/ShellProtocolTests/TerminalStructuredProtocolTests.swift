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
        let kinds: [ReixInputKind] = [
            .left, .right, .up, .down, .home, .end, .backspace, .delete,
            .enter, .cancel, .eof, .historyPrevious, .historyNext, .ignored,
            .pasteBegin, .pasteEnd, .compositionBegin, .compositionCancel,
            .focusGained, .focusLost, .stateReset
        ]
        var storage = [UInt8](repeating: 0, count: ReixInputProtocol.recordBytes)
        for kind in kinds {
            let event = ReixInputRecord(kind: kind, modifiers: [.shift], sequence: 42)!
            #expect(storage.withUnsafeMutableBufferPointer { event.encode(into: $0.baseAddress!, capacity: $0.count) })
            #expect(
                storage.withUnsafeBufferPointer {
                    ReixInputRecord.decode(
                        $0.baseAddress!,
                        length: $0.count
                    )
                } == event
            )
        }
        let resize = ReixInputRecord(kind: .resize, sequence: 43, width: 120, height: 40)!
        #expect(storage.withUnsafeMutableBufferPointer { resize.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == resize)
        let key = ReixInputRecord(
            kind: .key,
            modifiers: [.control],
            sequence: 44,
            logicalKey: .left,
            physicalKey: 105,
            phase: .repeatKey,
            repeatCount: 2
        )!
        #expect(storage.withUnsafeMutableBufferPointer { key.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == key)
        let chunk = Array("chunk".utf8)
        let textChunk = chunk.withUnsafeBufferPointer {
            ReixInputRecord(
                kind: .compositionCommit,
                sequence: 45,
                bytes: $0.baseAddress!,
                count: $0.count
            )!
        }
        #expect(storage.withUnsafeMutableBufferPointer { textChunk.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(
            storage.withUnsafeBufferPointer {
                ReixInputRecord.decode(
                    $0.baseAddress!,
                    length: $0.count
                )
            } == textChunk
        )
        #expect(MemoryLayout<ReixInputRecord>.size >= ReixInputProtocol.recordBytes)
    }

    @Test("input records fail closed on wire length, bits, zero sequence and malformed UTF-8")
    func inputFailures() {
        var storage = [UInt8](repeating: 0, count: ReixInputProtocol.recordBytes)
        var byte = UInt8(ascii: "x")
        let record = withUnsafePointer(to: &byte) { ReixInputRecord(kind: .insert, sequence: 1, bytes: $0, count: 1)! }
        #expect(storage.withUnsafeMutableBufferPointer { record.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(
            storage.withUnsafeBufferPointer {
                ReixInputRecord.decode(
                    $0.baseAddress!,
                    length: $0.count - 1
                )
            } == nil
        )
        storage[4] = 0x80
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == nil)
        storage[4] = 0
        storage[5] = 0x80
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == nil)
        storage[5] = 0
        storage[8] = 0
        storage[9] = 0
        storage[10] = 0
        storage[11] = 0
        #expect(storage.withUnsafeBufferPointer { ReixInputRecord.decode($0.baseAddress!, length: $0.count) } == nil)
        let malformed: [[UInt8]] = [[0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]]
        for bytes in malformed {
            bytes.withUnsafeBufferPointer {
                #expect(
                    ReixInputRecord(
                        kind: .insert,
                        sequence: 1,
                        bytes: $0.baseAddress!,
                        count: $0.count
                    ) == nil
                )
            }
        }
        for bytes in [[UInt8](repeating: 0x00, count: 1), [0x09], [0x0A], [0x1B], [0x7F], [0xC2, 0x80]] {
            bytes.withUnsafeBufferPointer {
                #expect(
                    ReixInputRecord(
                        kind: .insert,
                        sequence: 1,
                        bytes: $0.baseAddress!,
                        count: $0.count
                    ) == nil
                )
            }
        }
        let lf: [UInt8] = [0x0A]
        lf.withUnsafeBufferPointer {
            #expect(
                ReixInputRecord(
                    kind: .pasteChunk,
                    sequence: 1,
                    bytes: $0.baseAddress!,
                    count: $0.count
                ) != nil
            )
        }
    }

    @Test("TextSurface commands use the exact two-hundred-eighty-eight byte record")
    func surfaceCommands() {
        var storage = [UInt8](repeating: 0, count: ReixTextSurfaceProtocol.recordBytes)
        let text = Array("hello".utf8)
        let command = text.withUnsafeBufferPointer {
            ReixTextSurfaceCommand(
                kind: .replaceBuffer,
                sequence: 7,
                bytes: $0.baseAddress!,
                count: $0.count,
                previousRows: 2,
                previousCursorRow: 1,
                cursorRow: 0,
                cursorColumn: 3
            )!
        }
        #expect(storage.withUnsafeMutableBufferPointer { command.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(
            storage.withUnsafeBufferPointer {
                ReixTextSurfaceCommand.decode(
                    $0.baseAddress!,
                    length: $0.count
                )
            } == command
        )
        storage[24] = 1
        #expect(
            storage.withUnsafeBufferPointer {
                ReixTextSurfaceCommand.decode(
                    $0.baseAddress!,
                    length: $0.count
                )
            } == nil
        )
    }

    @Test("TextSurface presentation consumes only a matching typed command")
    func textSurfacePresentationSequenceFencePolicy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appending(
                path: "Sources/Reix/TextSurface/TextSurfaceSession.swift"
            ),
            encoding: .utf8
        )
        let method = try #require(
            source.components(
                separatedBy: "public mutating func present"
            ).dropFirst().first
        )
        #expect(method.contains("ring.push(command)"))
        #expect(method.contains("usable = false"))
        let server = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/VTAdapter/VTAdapter.swift"
            ),
            encoding: .utf8
        )
        #expect(server.contains("ReixInteractionSequence.isCorrelated(command.sequence)"))
    }

    @Test("presentation waits for a bounded ConsoleServer acknowledgement")
    func consoleAcknowledgementPolicy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let client = try String(
            contentsOf: root.appending(path: "Sources/Reix/Services/ConsoleServer/ConsoleClient.swift"),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appending(path: "Sources/Userland/VTAdapter/VTAdapter.swift"),
            encoding: .utf8
        )
        #expect(client.contains("public func flushNow() -> Bool"))
        #expect(client.contains("ConsoleOperation.drainPartial.message()"))
        #expect(client.contains("return flushed()"))
        #expect(client.contains("public func consoleFlush() -> Bool"))
        let present = try #require(
            adapter
                .components(separatedBy: "private mutating func present")
                .dropFirst()
                .first
        )
        let requested = try #require(
            present.range(of: ".presentationRequested")
        )
        let rendered = try #require(
            present.range(of: "let emittedBytes = render(command)")
        )
        let flushed = try #require(
            present.range(of: "guard consoleFlush() else")
        )
        let acknowledged = try #require(
            present.range(of: ".consoleAcknowledged")
        )
        #expect(requested.lowerBound < rendered.lowerBound)
        #expect(flushed.lowerBound < acknowledged.lowerBound)
    }

    @Test("serial hardware authority stays inside SerialServer")
    func serialHardwareAuthorityPolicy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serial = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/SerialServer/SerialServer.swift"
            ),
            encoding: .utf8
        )
        let console = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/ConsoleServer/ConsoleServer.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/VTAdapter/VTAdapter.swift"
            ),
            encoding: .utf8
        )
        let initSource = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/Init/Init.swift"
            ),
            encoding: .utf8
        )
        #expect(serial.contains("mapDevice(handle: device)"))
        #expect(serial.contains("irqWait(handle: interrupt"))
        #expect(!console.contains("mapDevice"))
        #expect(!console.contains("pl011"))
        #expect(!console.contains("irqWait"))
        #expect(!adapter.contains("mapDevice"))
        #expect(!adapter.contains("pl011"))
        #expect(!adapter.contains("irqWait"))
        #expect(!adapter.contains("irqAck"))
        let serialSpawn = try #require(
            initSource
                .components(separatedBy: "let serial = withUnsafeTemporaryAllocation")
                .dropFirst()
                .first?
                .components(separatedBy: "let console = withUnsafeTemporaryAllocation")
                .first
        )
        #expect(serialSpawn.contains("rights: [.read, .write]"))
        #expect(serialSpawn.contains("rights: []"))
        #expect(!serialSpawn.contains("rights: [.grant, .read, .write]"))
        let spawnSection = try #require(
            initSource
                .components(separatedBy: "let terminal = withUnsafeTemporaryAllocation")
                .dropFirst()
                .first
        )
        let adapterLaunch = try #require(
            spawnSection
                .components(separatedBy: "guard let terminalEndpoint")
                .first
        )
        #expect(!adapterLaunch.contains("BootCap.device.rawValue"))
        #expect(!adapterLaunch.contains("BootCap.interrupt.rawValue"))
        #expect(!adapterLaunch.contains(".grant"))
    }

    @Test("TextSurface and the adapter keep their operation boundaries")
    func adapterOperationBoundary() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let textSurface = try String(
            contentsOf: root.appending(
                path: "Sources/ReixABI/TextSurface/ReixTextSurfaceTransport.swift"
            ),
            encoding: .utf8
        )
        let adapter = try String(
            contentsOf: root.appending(
                path: "Sources/Userland/VTAdapter/VTAdapter.swift"
            ),
            encoding: .utf8
        )
        #expect(!textSurface.contains("sourcePull"))
        #expect(!textSurface.contains("produce = 5"))
        #expect(adapter.contains("case register = 0"))
        #expect(adapter.contains("case status = 1"))
        #expect(adapter.contains("case present = 2"))
        #expect(adapter.contains("case produce = 5"))
        #expect(adapter.contains("MessageTag(ReixInputSourceOperation.produce"))
    }

    @Test("InputServer starts without ambient service authority")
    func inputServerAuthorityPolicy() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(
            contentsOf: root.appending(path: "Sources/Userland/Init/Init.swift"),
            encoding: .utf8
        )
        let launch = try #require(
            source
                .components(separatedBy: "let inputServer = withUnsafeTemporaryAllocation")
                .dropFirst()
                .first?
                .components(separatedBy: "guard let inputEndpoint")
                .first
        )
        #expect(launch.contains("source: consoleEndpoint"))
        #expect(launch.contains("rights: [.send]"))
        #expect(!launch.contains("BootCap.nameServer.rawValue"))
        #expect(!launch.contains("BootCap.spawn.rawValue"))
        #expect(!launch.contains(".grant"))
    }

    @Test("terminal sequence domains wrap without crossing")
    func sequenceDomainsWrap() {
        #expect(ReixInteractionSequence.nextCorrelated(after: 0) == 1)
        #expect(ReixInteractionSequence.nextCorrelated(after: ReixInteractionSequence.maximumCorrelated) == 1)
        #expect(ReixInteractionSequence.nextAsynchronous(after: 0) == ReixInteractionSequence.asynchronousBit)
        #expect(ReixInteractionSequence.nextAsynchronous(after: UInt32.max) == ReixInteractionSequence.asynchronousBit)
        #expect(ReixInteractionSequence.isCorrelated(ReixInteractionSequence.maximumCorrelated))
        #expect(!ReixInteractionSequence.isCorrelated(ReixInteractionSequence.asynchronousBit))
    }
}
