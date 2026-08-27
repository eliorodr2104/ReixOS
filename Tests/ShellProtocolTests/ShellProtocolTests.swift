//
//  ShellProtocolTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

@Suite("Shell and terminal frames")
struct ShellProtocolTests {
    @Test("a versioned envelope round trips bounded records")
    func roundTrip() {
        var storage = [UInt8](repeating: 0, count: 128)
        let written = storage.withUnsafeMutableBufferPointer { bytes -> Int in
            guard var writer = ShellFrameWriter(
                bytes.baseAddress!,
                capacity: bytes.count,
                schema: .commandResult,
                sequence: 9,
                flags: [.end]
            ) else { return 0 }
            let appended = writer.appendScalar(.status, field: .status, value: 7)
            #expect(appended)
            return writer.finish()
        }

        #expect(written == 28)
        storage.withUnsafeBufferPointer { bytes in
            let frame = ShellFrame.decode(bytes.baseAddress!, length: written)
            #expect(frame?.envelope.version == ShellProtocol.version)
            #expect(frame?.envelope.schema == .commandResult)
            #expect(frame?.envelope.sequence == 9)
            #expect(frame?.envelope.flags.contains(.end) == true)
            #expect(frame?.recordCount == 1)
            #expect(frame?.scalar(at: 0)?.field == .status)
            #expect(frame?.scalar(at: 0)?.value == 7)
        }
    }

    @Test("unknown and malformed frames fail closed")
    func rejectsCorpus() {
        var storage = [UInt8](repeating: 0, count: 64)
        storage.withUnsafeMutableBufferPointer { bytes in
            bytes[0] = 2
            #expect(ShellFrame.decode(bytes.baseAddress!, length: 16) == nil)
            bytes[0] = 1
            bytes[2] = 0xFF
            bytes[3] = 0x7F
            #expect(ShellFrame.decode(bytes.baseAddress!, length: 16) == nil)
            bytes[2] = 1
            bytes[3] = 0
            bytes[12] = 1
            #expect(ShellFrame.decode(bytes.baseAddress!, length: 16) == nil)
        }
    }

    @Test("terminal events distinguish line eof and exact acknowledgements")
    func terminalEvents() {
        var storage = [UInt8](repeating: 0, count: 128)
        let written = storage.withUnsafeMutableBufferPointer { bytes in
            TerminalEvent.line(sequence: 12, bytes: UnsafePointer(bytes.baseAddress!), count: 3)
                .encode(into: bytes.baseAddress!, capacity: bytes.count)
        }

        storage.withUnsafeBufferPointer { bytes in
            let event = TerminalEvent.decode(bytes.baseAddress!, length: written)
            #expect(event?.kind == .line)
            #expect(event?.sequence == 12)
            #expect(event?.count == 3)
            #expect(TerminalAcknowledgement(sequence: 12, count: 3, status: .ok).accepts(event!))
            #expect(!TerminalAcknowledgement(sequence: 11, count: 3, status: .ok).accepts(event!))
            #expect(!TerminalAcknowledgement(sequence: 12, count: 2, status: .ok).accepts(event!))
            #expect(TerminalEvent.eof(sequence: 13).flags.contains(.end))
        }

        let longest    = [UInt8](repeating: UInt8(ascii: "x"), count: TerminalEvent.maximumPayload)
        var encoded    = [UInt8](repeating: 0, count: TerminalEvent.headerBytes + TerminalEvent.maximumPayload)
        let fullLength = longest.withUnsafeBufferPointer { source in
            encoded.withUnsafeMutableBufferPointer { destination in
                TerminalEvent.line(sequence: 14, bytes: source.baseAddress!, count: source.count)
                    .encode(into: destination.baseAddress!, capacity: destination.count)
            }
        }
        #expect(fullLength == TerminalEvent.headerBytes + TerminalEvent.maximumPayload)
        encoded.withUnsafeBufferPointer { bytes in
            #expect(TerminalEvent.decode(bytes.baseAddress!, length: fullLength)?.count == TerminalEvent.maximumPayload)
            #expect(TerminalEvent.decode(bytes.baseAddress!, length: fullLength - 1) == nil)
        }
        let tooLong = [UInt8](repeating: UInt8(ascii: "x"), count: TerminalEvent.maximumPayload + 1)
        tooLong.withUnsafeBufferPointer { bytes in
            #expect(TerminalEvent.line(sequence: 15, bytes: bytes.baseAddress!, count: bytes.count).status == .malformed)
        }
    }

    @Test("terminal events accept empty lines and reject incoherent variants")
    func terminalEventCoherence() {
        func raw(
            kind  : TerminalEventKind,
            status: TerminalEventStatus,
            flags : UInt32,
            count : UInt16
        ) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: TerminalEvent.headerBytes + Int(count))
            bytes[0] = UInt8(ShellProtocol.version)
            bytes[2] = UInt8(kind.rawValue)
            bytes[8] = UInt8(truncatingIfNeeded: flags)
            bytes[9] = UInt8(truncatingIfNeeded: flags >> 8)
            bytes[10] = UInt8(truncatingIfNeeded: flags >> 16)
            bytes[11] = UInt8(truncatingIfNeeded: flags >> 24)
            bytes[12] = UInt8(truncatingIfNeeded: count)
            bytes[13] = UInt8(truncatingIfNeeded: count >> 8)
            bytes[14] = UInt8(status.rawValue)
            return bytes
        }

        var empty  = [UInt8](repeating: 0, count: TerminalEvent.headerBytes)
        let length = empty.withUnsafeMutableBufferPointer { bytes in
            TerminalEvent.line(sequence: 31, bytes: bytes.baseAddress!, count: 0)
                .encode(into: bytes.baseAddress!, capacity: bytes.count)
        }
        empty.withUnsafeBufferPointer { bytes in
            #expect(TerminalEvent.decode(bytes.baseAddress!, length: length)?.count == 0)
        }

        let invalid: [[UInt8]] = [
            raw(kind: .line, status: .ok, flags: TerminalEventFlags.end.rawValue, count: 0),
            raw(kind: .eof, status: .ok, flags: 0, count: 0),
            raw(kind: .line, status: .malformed, flags: 0, count: 0),
            raw(kind: .line, status: .malformed, flags: TerminalEventFlags.cancelled.rawValue, count: 0),
            raw(kind: .resize, status: .ok, flags: 0, count: 0),
            raw(kind: .interrupt, status: .ok, flags: 0, count: 0),
        ]
        for candidate in invalid {
            candidate.withUnsafeBufferPointer { bytes in
                #expect(TerminalEvent.decode(bytes.baseAddress!, length: bytes.count) == nil)
            }
        }

        let error = raw(
            kind  : .line,
            status: .malformed,
            flags : TerminalEventFlags.error.rawValue,
            count : 0
        )
        error.withUnsafeBufferPointer { bytes in
            #expect(TerminalEvent.decode(bytes.baseAddress!, length: bytes.count)?.status == .malformed)
        }

        let interrupted       = TerminalEvent.interrupted(sequence: 32)
        let interruptedLength = empty.withUnsafeMutableBufferPointer { bytes in
            interrupted.encode(into: bytes.baseAddress!, capacity: bytes.count)
        }
        empty.withUnsafeBufferPointer { bytes in
            let decoded = TerminalEvent.decode(bytes.baseAddress!, length: interruptedLength)
            #expect(decoded?.kind == .interrupt)
            #expect(decoded?.status == .cancelled)
            #expect(decoded?.flags == [.cancelled])
        }
    }

    @Test("only the shell renderer turns typed records into presentation bytes")
    func renderer() {
        var storage = [UInt8](repeating: 0, count: 64)
        let written = storage.withUnsafeMutableBufferPointer { bytes -> Int in
            guard var writer = ShellFrameWriter(
                bytes.baseAddress!, capacity: bytes.count, schema: .commandResult
            ) else { return 0 }
            _ = writer.appendScalar(.status, field: .status, value: 7)
            return writer.finish()
        }
        let rendered = storage.withUnsafeBufferPointer { bytes in
            ShellTextRenderer.render(ShellFrame.decode(bytes.baseAddress!, length: written)!)
        }
        #expect(rendered?.count == 10)
        #expect(rendered?.bytes[0] == UInt8(ascii: "s"))
        #expect(rendered?.bytes[9] == UInt8(ascii: "\n"))
    }

    @Test("filesystem text chunks reserve first and last presentation bytes")
    func fileSystemTextChunkBounds() {
        #expect(ShellTextChunking.amount(remaining: 125, first: true) == 125)
        #expect(ShellTextChunking.amount(remaining: 126, first: true) == 125)
        #expect(ShellTextChunking.amount(remaining: 127, first: true) == 126)
        #expect(ShellTextChunking.amount(remaining: 127, first: false) == 127)
        #expect(ShellTextChunking.amount(remaining: 128, first: false) == 127)
        #expect(ShellTextChunking.amount(remaining: 129, first: false) == 128)

        var result  = ShellResult()
        let payload = [UInt8](repeating: UInt8(ascii: "x"), count: 129)
        payload.withUnsafeBufferPointer { bytes in
            var offset = 0
            while offset < bytes.count {
                let amount = ShellTextChunking.amount(
                    remaining: bytes.count - offset, first: offset == 0
                )
                #expect(amount > 0)
                let appended = result.appendFileSystemPath(
                    bytes.baseAddress! + offset, count: amount,
                    first: offset == 0, last: offset + amount == bytes.count
                )
                #expect(appended)
                offset += amount
            }
        }
        var rendered: [UInt8] = []
        for index in 0..<result.count {
            guard let presentation = ShellTextRenderer.render(result.record(at: index)!) else {
                Issue.record("renderer refused chunk")
                return
            }
            for byte in 0..<presentation.count { rendered.append(presentation.bytes[byte]) }
        }
        #expect(rendered == Array("  ".utf8) + payload + [UInt8(ascii: "\n")])
    }

    @Test("all filesystem findings render in bounded ordered chunks")
    func findingsChunks() {
        var storage = [UInt8](repeating: 0, count: 256)
        let written = storage.withUnsafeMutableBufferPointer { bytes -> Int in
            guard var writer = ShellFrameWriter(
                bytes.baseAddress!, capacity: bytes.count, schema: .fileSystemFindings,
                flags: [.end, .error]
            ) else { return 0 }
            let fields: [(ShellField, UInt32)] = [
                (.status, FSStatus.deviceFailed.rawValue),
                (.complete, 1),
                (.scrubDepth, 1),
                (.quotasChecked, 1),
                (.reclaimableBlocks, UInt32.max),
                (.ownedButFree, UInt32.max),
                (.claimedTwice, UInt32.max),
                (.impossible, UInt32.max),
                (.strayNames, UInt32.max),
                (.duplicateNames, UInt32.max),
                (.duplicateTargets, UInt32.max),
                (.brokenEntries, UInt32.max),
                (.nameScrubBudgetExhausted, 1),
                (.wrongQuota, UInt32.max),
                (.strayCharges, UInt32.max),
                (.selfParented, UInt32.max),
                (.roomsMended, UInt32.max),
                (.mapMended, 1),
                (.tooManyContainers, 1),
                (.safeToServe, 0),
            ]
            for (field, value) in fields {
                guard writer.appendScalar(field == .status ? .status : .scalar, field: field, value: value) else {
                    return 0
                }
            }
            return writer.finish()
        }

        var rendered  : [UInt8] = []
        var chunks    = 0
        let didRender = storage.withUnsafeBufferPointer { bytes in
            guard let frame = ShellFrame.decode(bytes.baseAddress!, length: written) else { return false }
            #expect(ShellFindingsFrame.validates(frame))
            return ShellTextRenderer.render(frame) { presentation in
                chunks += 1
                for index in 0..<presentation.count { rendered.append(presentation.bytes[index]) }
                return true
            }
        }
        let expected = Array(
            "status: 1\ncomplete: 1\nscrub-depth: 1\nquotas-checked: 1\nreclaimable-blocks: 4294967295\nowned-but-free: 4294967295\nclaimed-twice: 4294967295\nimpossible: 4294967295\nstray-names: 4294967295\nduplicate-names: 4294967295\nduplicate-targets: 4294967295\nbroken-entries: 4294967295\nname-scrub-budget-exhausted: 1\nwrong-quota: 4294967295\nstray-charges: 4294967295\nself-parented: 4294967295\nrooms-mended: 4294967295\nmap-mended: 1\ntoo-many-containers: 1\nsafe-to-serve: 0\n".utf8
        )
        #expect(didRender)
        #expect(chunks == 5)
        #expect(rendered == expected)

        var duplicate = storage
        duplicate[30] = UInt8(ShellField.status.rawValue)
        duplicate.withUnsafeBufferPointer { bytes in
            #expect(!ShellFindingsFrame.validates(ShellFrame.decode(bytes.baseAddress!, length: written)!))
        }
        var badBoolean = storage
        badBoolean[36] = 2
        badBoolean.withUnsafeBufferPointer { bytes in
            #expect(!ShellFindingsFrame.validates(ShellFrame.decode(bytes.baseAddress!, length: written)!))
        }
        var incoherentFlags = storage
        incoherentFlags[8] = UInt8(ShellFrameFlags.end.rawValue)
        incoherentFlags.withUnsafeBufferPointer { bytes in
            #expect(!ShellFindingsFrame.validates(ShellFrame.decode(bytes.baseAddress!, length: written)!))
        }
        var incoherentStatus = storage
        incoherentStatus[24] = UInt8(FSStatus.ok.rawValue)
        incoherentStatus.withUnsafeBufferPointer { bytes in
            #expect(!ShellFindingsFrame.validates(ShellFrame.decode(bytes.baseAddress!, length: written)!))
        }
    }

    @Test("a failed terminal presentation keeps only the unsent shell bytes")
    func outputFailureKeepsUnsentBytes() {
        var output = ShellOutputBuffer()
        for value in 0..<130 { output.append(UInt8(value)) }

        var calls = 0
        var first : [UInt8] = []
        let sent  = output.flush { bytes, count in
            calls += 1
            if calls == 1 {
                for index in 0..<count { first.append(bytes[index]) }
                return true
            }
            return false
        }
        #expect(!sent)
        #expect(first == Array(0..<128).map(UInt8.init))

        var remaining: [UInt8] = []
        #expect(output.flush { bytes, count in
            for index in 0..<count { remaining.append(bytes[index]) }
            return true
        })
        #expect(remaining == [128, 129])
    }

    @Test("shell output has an exact limit and fails closed after overflow")
    func outputOverflowIsObservable() {
        var exact = ShellOutputBuffer()
        for _ in 0..<4096 {
            let appended = exact.append(UInt8(ascii: "x"))
            #expect(appended)
        }
        #expect(!exact.overflowed)
        var exactCount = 0
        #expect(exact.flush { _, count in
            exactCount += count
            return true
        })
        #expect(exactCount == 4096)

        var overflowed = ShellOutputBuffer()
        for _ in 0..<4096 { _ = overflowed.append(UInt8(ascii: "x")) }
        let refused = overflowed.append(UInt8(ascii: "y"))
        #expect(!refused)
        #expect(overflowed.overflowed)
        var sends = 0
        #expect(!overflowed.flush { _, _ in
            sends += 1
            return true
        })
        #expect(sends == 0)

        overflowed.reset()
        #expect(!overflowed.overflowed)
        let retriedAppend = overflowed.append(UInt8(ascii: "z"))
        #expect(retriedAppend)
        var retried: [UInt8] = []
        #expect(overflowed.flush { bytes, count in
            for index in 0..<count { retried.append(bytes[index]) }
            return true
        })
        #expect(retried == [UInt8(ascii: "z")])
    }

    @Test("an invalid renderer outcome invalidates buffered output without retransmission")
    func outputInvalidationFailsClosed() {
        var output = ShellOutputBuffer()
        let first  = output.append(UInt8(ascii: "x"))
        #expect(first)
        output.invalidate()
        #expect(output.failed)
        var calls = 0
        #expect(!output.flush { _, _ in calls += 1; return true })
        #expect(calls == 0)
        output.reset()
        #expect(!output.failed)
        let retry = output.append(UInt8(ascii: "y"))
        #expect(retry)
        #expect(output.flush { _, _ in true })
    }

    @Test("a large mapped window remains bounded by protocol payload not rejected")
    func largeWindow() {
        var storage = [UInt8](repeating: 0, count: 4096)
        storage.withUnsafeMutableBufferPointer { bytes in
            guard var writer = ShellFrameWriter(
                bytes.baseAddress!, capacity: bytes.count, schema: .fileSystemFindings
            ) else {
                Issue.record("large attached window was rejected")
                return
            }
            let appended = writer.appendScalar(.status, field: .status, value: 0)
            #expect(appended)
            #expect(writer.finish() == 28)
        }
    }

    @Test("an in-place shared-page presentation preserves every payload byte")
    func inPlacePresentation() {
        let expected = Array("shared-page presentation bytes\\n".utf8)
        var storage  = [UInt8](repeating: 0, count: 4096)
        let written  = storage.withUnsafeMutableBufferPointer { bytes -> Int in
            let payload = bytes.baseAddress! + ShellProtocol.headerBytes + ShellProtocol.recordBytes
            for index in expected.indices { payload[index] = expected[index] }
            guard var writer = ShellFrameWriter(
                bytes.baseAddress!, capacity: bytes.count, schema: .presentation, sequence: 18
            ) else {
                Issue.record("presentation frame")
                return 0
            }
            let appended = writer.appendInPlace(
                .text, field: .text, payload: payload, count: expected.count
            )
            #expect(appended)
            return writer.finish()
        }

        storage.withUnsafeBufferPointer { bytes in
            let frame = ShellFrame.decode(bytes.baseAddress!, length: written)
            let text  = frame?.text(at: 0)
            #expect(frame?.envelope.schema == .presentation)
            #expect(text?.count == expected.count)
            for index in expected.indices { #expect(text?.bytes[index] == expected[index]) }
        }
    }

    @Test("core and process results retain semantic fields before rendering")
    func semanticCommandResults() {
        var result  = ShellResult()
        let stopped = result.appendPresentation("  stopping\n")
        let process = result.appendProcess(pid: 41, status: 2, name: "Top.elf")
        let exited  = result.appendProcessExit(pid: 41, code: 0)
        #expect(stopped)
        #expect(process)
        #expect(exited)

        #expect(result.count == 3)
        #expect(result.record(at: 0)?.kind == .presentation)
        #expect(result.record(at: 1)?.kind == .process)
        #expect(result.record(at: 1)?.value0 == 41)
        #expect(result.record(at: 1)?.value1 == 2)
        #expect(result.record(at: 1)?.field0 == .pid)
        #expect(result.record(at: 1)?.field1 == .processStatus)
        #expect(result.record(at: 1)?.field2 == .programName)
        #expect(result.record(at: 2)?.kind == .processExit)
        #expect(result.record(at: 2)?.field1 == .exitCode)
        guard let rendered = ShellTextRenderer.render(result.record(at: 2)!) else {
            Issue.record("process exit record did not render")
            return
        }
        let expected = Array("[41] exited with 0\n".utf8)
        #expect(rendered.count == expected.count)
        for index in expected.indices { #expect(rendered.bytes[index] == expected[index]) }
    }

    @Test("block and filesystem values retain typed fields before rendering")
    func storageCommandResults() {
        var result   = ShellResult()
        let geometry = result.appendBlockGeometry(sectors: 64, sectorSize: 512, maximumRun: 8)
        let room     = result.appendFileSystemRoom(freeBlocks: 31, dirty: true, quarantined: false)
        let entry    = result.appendFileSystemEntry(kind: .folder, name: "docs")

        #expect(geometry)
        #expect(room)
        #expect(entry)
        #expect(result.record(at: 0)?.kind == .blockGeometry)
        #expect(result.record(at: 0)?.field0 == .sectorCount)
        #expect(result.record(at: 1)?.kind == .fileSystemRoom)
        #expect(result.record(at: 1)?.field0 == .freeBlocks)
        #expect(result.record(at: 2)?.kind == .fileSystemEntry)
        #expect(result.record(at: 2)?.field0 == .fileSystemKind)
        #expect(result.record(at: 2)?.field1 == .entryName)
        #expect(ShellTextRenderer.render(result.record(at: 0)!)?.count == 52)
        #expect(ShellTextRenderer.render(result.record(at: 2)!)?.count == 10)

        let tooLong = [UInt8](repeating: UInt8(ascii: "x"), count: 129)
        let refused = tooLong.withUnsafeBufferPointer { bytes in
            result.appendFileSystemEntry(kind: .file, name: bytes.baseAddress!, count: bytes.count)
        }
        #expect(!refused)
        #expect(result.truncated)
    }
}
