//
//  ShellTextRenderer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public enum ShellTextRenderer {
    public static func render(_ record: ShellResultRecord) -> ShellPresentation? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        var count = 0

        switch record.kind {
            case .presentation:
                guard record.field0 == .text,
                      record.field1 == .none,
                      record.field2 == .none,
                      append(record.text, count: record.textCount, into: &bytes, count: &count)
                else { return nil }

            case .fileSystemStatus:
                guard record.field0 == .status,
                      record.field1 == .none,
                      record.field2 == .none,
                      append(fileSystemStatus(record.value0), into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .power:
                guard record.field0 == .powerState,
                      record.field1 == .none,
                      record.field2 == .none
                else { return nil }
                switch record.value0 {
                    case 0:
                        guard append("  this shell was not given the right to stop the machine\n", into: &bytes, count: &count) else { return nil }
                    case 1:
                        guard append("  stopping\n", into: &bytes, count: &count) else { return nil }
                    case 2:
                        guard append("  the machine would not stop\n", into: &bytes, count: &count) else { return nil }
                    default: return nil
                }

            case .processList:
                guard record.field0 == .none,
                      record.field1 == .none,
                      record.field2 == .none,
                      append("\n   PID  NAME              STATUS\n", into: &bytes, count: &count)
                else { return nil }

            case .process:
                guard record.field0 == .pid,
                      record.field1 == .processStatus,
                      record.field2 == .programName,
                      record.textCount >= 0,
                      record.textCount <= record.text.count,
                      appendDecimal(record.value0, paddedTo: 6, into: &bytes, count: &count),
                      append("  ", into: &bytes, count: &count),
                      append(record.text, count: min(record.textCount, 16), into: &bytes, count: &count),
                      appendSpaces(16 - min(record.textCount, 16), into: &bytes, count: &count),
                      append("  ", into: &bytes, count: &count),
                      append(processStatus(record.value1), into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .processExit:
                guard record.field0 == .pid,
                      record.field1 == .exitCode,
                      record.field2 == .none,
                      append("[", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append("] exited with ", into: &bytes, count: &count),
                      appendDecimal(record.value1, into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .processStart:
                guard record.field0 == .status,
                      record.field1 == .programName,
                      record.field2 == .none,
                      record.textCount >= 0,
                      record.textCount <= record.text.count
                else { return nil }
                switch record.value0 {
                    case 0:
                        guard append("this shell has no console to hand on\n", into: &bytes, count: &count) else { return nil }
                    case 1:
                        guard append("could not start ", into: &bytes, count: &count),
                              append(record.text, count: record.textCount, into: &bytes, count: &count),
                              append("\n", into: &bytes, count: &count)
                        else { return nil }
                    default: return nil
                }

            case .truncated:
                guard record.field0 == .none,
                      record.field1 == .none,
                      record.field2 == .none,
                      append("  result truncated\n", into: &bytes, count: &count)
                else { return nil }

            case .unmount:
                guard record.field0 == .status,
                      record.field1 == .none,
                      record.field2 == .none
                else { return nil }
                if record.value0 != 0 {
                    guard append("  the disk would not unmount, stopping anyway\n", into: &bytes, count: &count) else { return nil }
                }

            case .blockGeometry:
                guard record.field0 == .sectorCount,
                      record.field1 == .sectorSize,
                      record.field2 == .maximumRun,
                      append("  sectors  ", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append("\n  bytes    ", into: &bytes, count: &count)
                else { return nil }
                let (bytesOnDisk, overflow) = record.value0.multipliedReportingOverflow(by: record.value1)
                guard !overflow,
                      appendDecimal(bytesOnDisk, into: &bytes, count: &count),
                      append("\n  per call ", into: &bytes, count: &count),
                      appendDecimal(record.value2, into: &bytes, count: &count),
                      append(" sectors\n", into: &bytes, count: &count)
                else { return nil }

            case .blockRead:
                guard record.field0 == .sector,
                      record.field1 == .data,
                      record.field2 == .text,
                      record.textCount >= 0,
                      record.textCount <= 64,
                      append("  sector ", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append("\n  ", into: &bytes, count: &count),
                      appendPrintable(record.text, count: record.textCount, into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .blockStatus:
                guard record.field0 == .blockStatus,
                      record.field1 == .none,
                      record.field2 == .none,
                      append("read refused: ", into: &bytes, count: &count),
                      append(blockStatus(record.value0), into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemRoom:
                guard record.field0 == .freeBlocks,
                      record.field1 == .fileSystemFlags,
                      record.field2 == .none,
                      append("  room left   ", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append(" blocks\n", into: &bytes, count: &count),
                      append(record.value1 & 1 != 0 ? "  the disk was not unmounted cleanly\n" : "  clean\n", into: &bytes, count: &count)
                else { return nil }
                if record.value1 & 2 != 0 {
                    guard append("  the disk contradicted itself and is now read-only\n", into: &bytes, count: &count) else { return nil }
                }

            case .fileSystemPath:
                guard record.field0 == .sequence,
                      record.field1 == .text,
                      record.field2 == .none,
                      record.value0 & ~UInt64(3) == 0,
                      appendPath(record, into: &bytes, count: &count)
                else { return nil }

            case .fileSystemEntry:
                guard record.field0 == .fileSystemKind,
                      record.field1 == .entryName,
                      record.field2 == .text,
                      record.textCount >= 0,
                      record.textCount <= record.text.count,
                      append("  ", into: &bytes, count: &count),
                      append(record.text, count: record.textCount, into: &bytes, count: &count),
                      append(fileSystemSuffix(record.value0), into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemInfo:
                guard record.field0 == .fileSystemKind,
                      record.field1 == .byteCount,
                      record.field2 == .blockCount,
                      append("  kind     ", into: &bytes, count: &count),
                      append(fileSystemKind(record.value0), into: &bytes, count: &count),
                      append("\n  bytes    ", into: &bytes, count: &count),
                      appendDecimal(record.value1, into: &bytes, count: &count),
                      append("\n  blocks   ", into: &bytes, count: &count),
                      appendDecimal(record.value2, into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemTimes:
                guard record.field0 == .createdAt,
                      record.field1 == .modifiedAt,
                      record.field2 == .none,
                      append("  made     ", into: &bytes, count: &count),
                      appendStamp(record.value0, into: &bytes, count: &count),
                      append("\n  changed  ", into: &bytes, count: &count),
                      appendStamp(record.value1, into: &bytes, count: &count),
                      append("\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemRead:
                guard record.field0 == .sequence,
                      record.field1 == .data,
                      record.field2 == .text,
                      record.value0 & ~UInt64(3) == 0,
                      appendRead(record, into: &bytes, count: &count)
                else { return nil }

            case .fileSystemReadTail:
                guard record.field0 == .byteCount,
                      record.field1 == .blockCount,
                      record.field2 == .none,
                      append("  (first ", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append(" of ", into: &bytes, count: &count),
                      appendDecimal(record.value1, into: &bytes, count: &count),
                      append(" bytes)\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemWrite:
                guard record.field0 == .byteCount,
                      record.field1 == .none,
                      record.field2 == .none,
                      append("  wrote ", into: &bytes, count: &count),
                      appendDecimal(record.value0, into: &bytes, count: &count),
                      append(" bytes\n", into: &bytes, count: &count)
                else { return nil }

            case .fileSystemEmpty:
                guard record.field0 == .none,
                      record.field1 == .none,
                      record.field2 == .none,
                      append("  (empty)\n", into: &bytes, count: &count)
                else { return nil }
        }

        return ShellPresentation(bytes: bytes, count: count)
    }

    public static func render(_ frame: ShellFrame) -> ShellPresentation? {
        guard frame.envelope.schema == .commandResult || frame.envelope.schema == .fileSystemFindings else {
            return nil
        }
        guard frame.envelope.schema != .fileSystemFindings || ShellFindingsFrame.validates(frame) else {
            return nil
        }
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        var count = 0
        for index in 0..<frame.recordCount {
            guard let scalar = frame.scalar(at: index),
                  append(field: scalar.field, value: scalar.value, into: &bytes, count: &count)
            else { return nil }
        }
        return ShellPresentation(bytes: bytes, count: count)
    }

    public static func render(
        _ frame: ShellFrame,
          emit   : (ShellPresentation) -> Bool
    ) -> Bool {
        guard frame.envelope.schema == .commandResult || frame.envelope.schema == .fileSystemFindings else {
            return false
        }
        guard frame.envelope.schema != .fileSystemFindings || ShellFindingsFrame.validates(frame) else {
            return false
        }
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        var count = 0

        for index in 0..<frame.recordCount {
            guard let scalar = frame.scalar(at: index) else { return false }
            var record      = InlineArray<128, UInt8>(repeating: 0)
            var recordCount = 0
            guard append(field: scalar.field, value: scalar.value, into: &record, count: &recordCount) else {
                return false
            }

            if count > bytes.count - recordCount {
                guard emit(ShellPresentation(bytes: bytes, count: count)) else { return false }
                bytes = InlineArray(repeating: 0)
                count = 0
            }

            for byte in 0..<recordCount {
                bytes[count] = record[byte]
                count += 1
            }
        }

        return count == 0 || emit(ShellPresentation(bytes: bytes, count: count))
    }

    private static func append(
        field: ShellField,
        value: UInt32,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        let label: StaticString
        switch field {
            case .status: label = "status: "
            case .freeBlocks: label = "free-blocks: "
            case .reclaimableBlocks: label = "reclaimable-blocks: "
            case .claimedTwice: label = "claimed-twice: "
            case .strayNames: label = "stray-names: "
            case .duplicateNames: label = "duplicate-names: "
            case .tooManyContainers: label = "too-many-containers: "
            case .safeToServe: label = "safe-to-serve: "
            case .complete: label = "complete: "
            case .ownedButFree: label = "owned-but-free: "
            case .impossible: label = "impossible: "
            case .duplicateTargets: label = "duplicate-targets: "
            case .brokenEntries: label = "broken-entries: "
            case .nameScrubBudgetExhausted: label = "name-scrub-budget-exhausted: "
            case .wrongQuota: label = "wrong-quota: "
            case .strayCharges: label = "stray-charges: "
            case .scrubDepth: label = "scrub-depth: "
            case .quotasChecked: label = "quotas-checked: "
            case .selfParented: label = "self-parented: "
            case .roomsMended: label = "rooms-mended: "
            case .mapMended: label = "map-mended: "
            case .text: return false
        }
        guard count <= bytes.count - label.utf8CodeUnitCount - 11 else { return false }
        for index in 0..<label.utf8CodeUnitCount {
            bytes[count] = label.utf8Start[index]
            count += 1
        }
        var number  = value
        var divisor : UInt32 = 1
        while divisor <= number / 10 { divisor *= 10 }
        while divisor > 0 {
            bytes[count] = UInt8(ascii: "0") + UInt8(number / divisor)
            count += 1
            number %= divisor
            divisor /= 10
        }
        bytes[count] = UInt8(ascii: "\n")
        count += 1
        return true
    }

    private static func append(
        _ text: StaticString,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        guard count <= bytes.count - text.utf8CodeUnitCount else { return false }
        for index in 0..<text.utf8CodeUnitCount {
            bytes[count] = text.utf8Start[index]
            count += 1
        }
        return true
    }

    private static func append(
        _ source: InlineArray<128, UInt8>,
        count sourceCount: Int,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        guard sourceCount >= 0,
              sourceCount <= source.count,
              count <= bytes.count - sourceCount
        else { return false }
        for index in 0..<sourceCount {
            bytes[count] = source[index]
            count += 1
        }
        return true
    }

    private static func appendSpaces(
        _ amount: Int,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        guard amount >= 0, count <= bytes.count - amount else { return false }
        for _ in 0..<amount {
            bytes[count] = UInt8(ascii: " ")
            count += 1
        }
        return true
    }

    private static func appendPrintable(
        _ source: InlineArray<128, UInt8>,
        count sourceCount: Int,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        guard sourceCount >= 0,
              sourceCount <= source.count,
              count <= bytes.count - sourceCount
        else { return false }
        for index in 0..<sourceCount {
            let byte = source[index]
            bytes[count] = byte >= 0x20 && byte < 0x7F ? byte : UInt8(ascii: ".")
            count += 1
        }
        return true
    }

    private static func appendRead(
        _ record: ShellResultRecord,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        if record.value0 & 1 != 0, !append("  ", into: &bytes, count: &count) { return false }
        guard appendPrintable(record.text, count: record.textCount, into: &bytes, count: &count) else { return false }
        if record.value0 & 2 != 0, !append("\n", into: &bytes, count: &count) { return false }
        return true
    }

    private static func appendPath(
        _ record: ShellResultRecord,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        if record.value0 & 1 != 0, !append("  ", into: &bytes, count: &count) { return false }
        guard append(record.text, count: record.textCount, into: &bytes, count: &count) else { return false }
        if record.value0 & 2 != 0, !append("\n", into: &bytes, count: &count) { return false }
        return true
    }

    private static func appendDecimal(
        _ value: UInt64,
        paddedTo width: Int = 0,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        var digits      = InlineArray<20, UInt8>(repeating: 0)
        var number      = value
        var digitsCount = 0
        repeat {
            digits[digitsCount] = UInt8(ascii: "0") + UInt8(number % 10)
            digitsCount += 1
            number /= 10
        } while number > 0
        guard width >= 0,
              count <= bytes.count - max(width, digitsCount)
        else { return false }
        if digitsCount < width {
            for _ in digitsCount..<width {
                bytes[count] = UInt8(ascii: " ")
                count += 1
            }
        }
        while digitsCount > 0 {
            digitsCount -= 1
            bytes[count] = digits[digitsCount]
            count += 1
        }
        return true
    }

    private static func processStatus(_ rawValue: UInt64) -> StaticString {
        switch ProcessStatusCode(rawValue: UInt8(truncatingIfNeeded: rawValue)) {
            case .new?: "New"
            case .ready?: "Ready"
            case .running?: "Running"
            case .waiting?: "Waiting"
            case .blockedOnSend?: "Blocked on Send"
            case .blockedOnReceive?: "Blocked on Receive"
            case .blockedOnReply?: "Blocked on Reply"
            case .terminated?: "Terminated"
            case nil: "unknown"
        }
    }

    private static func blockStatus(_ rawValue: UInt64) -> StaticString {
        switch BlockStatus(rawValue: UInt32(truncatingIfNeeded: rawValue)) {
            case .ok?: "ok"
            case .outOfRange?: "no such sector on this disk"
            case .tooLong?: "more sectors than one call can carry"
            case .notAttached?: "this shell is not attached to the disk"
            case .deviceRefused?: "the disk refused the request"
            case .queueFull?: "the disk is busy with other requests, try again"
            case .unreachable?: "the disk did not answer"
            case .volumeHeld?: "the file system holds the disk, try fs.unmount first"
            case .notMounted?: "this shell does not hold the disk"
            case .readOnly?: "this shell was not given the right to do that to the disk"
            case .notAuthorised?: "this shell was not given the authority to ask that"
            case .durabilityUnknown?: "the disk will not say what a finished write achieves"
            case .duplicateTag?: "that request is already in flight under the same name"
            case nil: "unknown"
        }
    }

    private static func fileSystemSuffix(_ rawValue: UInt64) -> StaticString {
        switch FSKind(rawValue: UInt8(truncatingIfNeeded: rawValue)) {
            case .container?: "  ::"
            case .folder?: "  /"
            case .file?, .free?, nil: ""
        }
    }

    private static func fileSystemKind(_ rawValue: UInt64) -> StaticString {
        switch FSKind(rawValue: UInt8(truncatingIfNeeded: rawValue)) {
            case .file?: "file"
            case .folder?: "folder"
            case .container?: "container"
            case .free?, nil: "nothing"
        }
    }

    private static func fileSystemStatus(_ rawValue: UInt64) -> StaticString {
        switch FSStatus(rawValue: UInt32(truncatingIfNeeded: rawValue)) {
            case .ok?: "  done"
            case .deviceFailed?: "  the disk stopped answering"
            case .notFormatted?: "  the disk holds no file system"
            case .notFound?: "  no such name"
            case .exists?: "  that name is taken"
            case .badName?: "  a name may not look like that"
            case .wrongKind?: "  not that kind of thing"
            case .noSpace?: "  no room left here"
            case .notEmpty?: "  that folder still has something in it"
            case .tooFragmented?: "  the file is in too many pieces"
            case .readOnly?: "  this shell was not given the right to do that"
            case .busy?: "  something else is in the middle of writing that"
            case .unreachable?: "  the file system did not answer, it may be gone"
            case .quarantined?: "  the disk contradicted itself and is now read-only"
            case .durabilityUnknown?: "  the disk will not say what a finished write achieves"
            case .tooManyChanges?: "  that change touches more of the disk than one step can hold"
            case .noTransaction?: "  the file system refused itself, which is a bug and not a disk"
            case .tooDeep?: "  that would nest deeper than a path can be followed back out of"
            case .tooManyBlocks?: "  that disk is larger than this build is declared to serve"
            case .unsupportedCapacity?: "  this version cannot represent another container"
            case .bufferTooSmall?: "  the result did not fit in the buffer provided"
            case .pastTheEnd?: "  a file has no holes here, so a write starts at the end or inside"
            case nil: "  unknown file system status"
        }
    }

    private static func appendStamp(
        _ nanoseconds: UInt64,
        into bytes: inout InlineArray<128, UInt8>,
        count: inout Int
    ) -> Bool {
        let time = Time(nanoseconds: nanoseconds)
        guard time.isKnown else { return append("unknown", into: &bytes, count: &count) }
        let civil = time.civil
        return appendDecimal(UInt64(civil.year), into: &bytes, count: &count)
            && append("-", into: &bytes, count: &count)
            && appendDecimal(UInt64(civil.month), paddedTo: 2, into: &bytes, count: &count)
            && append("-", into: &bytes, count: &count)
            && appendDecimal(UInt64(civil.day), paddedTo: 2, into: &bytes, count: &count)
            && append(" ", into: &bytes, count: &count)
            && appendDecimal(UInt64(civil.hour), paddedTo: 2, into: &bytes, count: &count)
            && append(":", into: &bytes, count: &count)
            && appendDecimal(UInt64(civil.minute), paddedTo: 2, into: &bytes, count: &count)
            && append(":", into: &bytes, count: &count)
            && appendDecimal(UInt64(civil.second), paddedTo: 2, into: &bytes, count: &count)
    }
}
