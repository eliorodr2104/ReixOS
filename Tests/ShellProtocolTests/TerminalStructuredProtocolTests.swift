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

    @Test("TextSurface v3 has one exact frame envelope")
    func surfaceFrames() {
        var storage = [UInt8](repeating: 0, count: ReixTextSurfaceProtocol.recordBytes)
        let descriptor = ReixTextSurfaceFrameDescriptor(
            kind: .snapshot,
            correlation: 7,
            revision: 1,
            baseRevision: 0,
            textLength: 5,
            columns: 80,
            rows: 24,
            cursorRow: 0,
            cursorColumn: 5,
            viewportRows: 6
        )!
        var metadata = [UInt8](repeating: 0, count: ReixTextSurfaceFrameDescriptor.wireBytes)
        #expect(metadata.withUnsafeMutableBufferPointer {
            descriptor.encode(into: $0.baseAddress!, capacity: $0.count)
        })
        #expect(metadata[2] == UInt8(ReixTextSurfaceFrameMode.editor.rawValue))
        #expect(metadata.withUnsafeBufferPointer {
            ReixTextSurfaceFrameDescriptor.decode($0.baseAddress!, length: $0.count)?.mode
                == .editor
        })
        var malformedMetadata = metadata
        malformedMetadata[2] = 0
        #expect(malformedMetadata.withUnsafeBufferPointer {
            ReixTextSurfaceFrameDescriptor.decode($0.baseAddress!, length: $0.count)
                == nil
        })
        let record = metadata.withUnsafeBufferPointer {
            ReixTextSurfaceFrameRecord(
                kind: .begin,
                transaction: 11,
                chunk: 0,
                chunks: 3,
                checksum: 42,
                bytes: $0.baseAddress!,
                count: $0.count
            )!
        }
        #expect(storage.withUnsafeMutableBufferPointer { record.encode(into: $0.baseAddress!, capacity: $0.count) })
        #expect(
            storage.withUnsafeBufferPointer {
                ReixTextSurfaceFrameRecord.decode($0.baseAddress!, length: $0.count)
            } == record
        )
        storage[20] = 1
        #expect(
            storage.withUnsafeBufferPointer {
                ReixTextSurfaceFrameRecord.decode($0.baseAddress!, length: $0.count)
            } == nil
        )
        #expect(ReixTextSurfaceTransport.pages == 3)
        #expect(ReixTextSurfaceTransport.version == 3)
        #expect(ReixTextSurfaceTransport.maximumFrameRecords <= ReixTextSurfaceTransport.capacity)
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
