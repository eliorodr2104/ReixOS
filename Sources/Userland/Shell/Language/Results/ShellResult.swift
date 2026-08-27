//
//  ShellResult.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public struct ShellResult {
    private var records = InlineArray<48, ShellResultRecord?>(repeating: nil)
    public private(set) var count = 0
    public private(set) var truncated = false

    public init() {}

    public func record(at index: Int) -> ShellResultRecord? {
        guard index >= 0, index < count else { return nil }
        return records[index]
    }

    public mutating func appendPresentation(_ text: StaticString) -> Bool {
        guard let record = ShellResultRecord.presentation(text) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendFileSystemStatus(_ status: UInt32) -> Bool {
        append(.scalar(.fileSystemStatus, UInt64(status), field0: .status))
    }

    public mutating func appendPower(_ state: UInt64) -> Bool {
        append(.scalar(.power, state, field0: .powerState))
    }

    public mutating func appendUnmount(_ status: UInt32) -> Bool {
        append(.scalar(.unmount, UInt64(status), field0: .status))
    }

    public mutating func appendProcessList() -> Bool {
        append(.scalar(.processList))
    }

    public mutating func appendProcess(
          pid   : UInt64,
          status: UInt32,
          name  : StaticString
    ) -> Bool {
        guard let record = ShellResultRecord.process(pid: pid, status: status, name: name) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendProcess(
          pid   : UInt64,
          status: UInt32,
          name  : UnsafePointer<UInt8>,
          count : Int
    ) -> Bool {
        guard let record = ShellResultRecord.process(pid: pid, status: status, name: name, count: count) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendProcess(
          pid   : UInt64,
          status: UInt32,
          name  : InlineArray<16, UInt8>,
          count : Int
    ) -> Bool {
        guard let record = ShellResultRecord.process(pid: pid, status: status, name: name, count: count) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendProcessExit(
          pid : UInt64,
          code: UInt64
    ) -> Bool {
        append(.scalar(.processExit, pid, code, field0: .pid, field1: .exitCode))
    }

    public mutating func appendProcessStart(
        _ status: UInt64,
          name  : UnsafePointer<UInt8>,
          count : Int
    ) -> Bool {
        guard let record = ShellResultRecord.processStart(status, name: name, count: count) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendBlockGeometry(
          sectors   : UInt64,
          sectorSize: UInt64,
          maximumRun: UInt64
    ) -> Bool {
        append(.scalar(
            .blockGeometry,
            sectors,
            sectorSize,
            maximumRun,
            field0: .sectorCount,
            field1: .sectorSize,
            field2: .maximumRun
        ))
    }

    public mutating func appendBlockStatus(_ status: UInt32) -> Bool {
        append(.scalar(.blockStatus, UInt64(status), field0: .blockStatus))
    }

    public mutating func appendBlockRead(
          sector: UInt64,
          bytes : UnsafePointer<UInt8>,
          count : Int
    ) -> Bool {
        guard let record = ShellResultRecord.text(
            .blockRead, value0: sector, field0: .sector, field1: .data, source: bytes, count: count
        ) else { truncated = true; return false }
        return append(record)
    }

    public mutating func appendFileSystemRoom(
          freeBlocks : UInt32,
          dirty      : Bool,
          quarantined: Bool
    ) -> Bool {
        let flags = (dirty ? UInt64(1) : 0) | (quarantined ? UInt64(2) : 0)
        return append(.scalar(.fileSystemRoom, UInt64(freeBlocks), flags, field0: .freeBlocks, field1: .fileSystemFlags))
    }

    public mutating func appendFileSystemEntry(
          kind: FSKind,
          name: StaticString
    ) -> Bool {
        guard let record = ShellResultRecord.text(
            .fileSystemEntry,
            value0: UInt64(kind.rawValue),
            field0: .fileSystemKind,
            field1: .entryName,
            field2: .text,
            source: name.utf8Start,
            count: name.utf8CodeUnitCount
        ) else { truncated = true; return false }
        return append(record)
    }

    public mutating func appendFileSystemEntry(
          kind : FSKind,
          name : UnsafePointer<UInt8>,
          count: Int
    ) -> Bool {
        guard let record = ShellResultRecord.text(
            .fileSystemEntry, value0: UInt64(kind.rawValue), field0: .fileSystemKind, field1: .entryName,
            source: name, count: count
        ) else { truncated = true; return false }
        return append(record)
    }

    public mutating func appendFileSystemEntry(
          kind : FSKind,
          name : InlineArray<56, UInt8>,
          count: Int
    ) -> Bool {
        guard let record = ShellResultRecord.fileSystemEntry(kind: kind, name: name, count: count) else {
            truncated = true
            return false
        }
        return append(record)
    }

    public mutating func appendFileSystemPath(
        _ bytes: UnsafePointer<UInt8>,
          count: Int,
          first: Bool,
          last : Bool
    ) -> Bool {
        let flags = (first ? UInt64(1) : 0) | (last ? UInt64(2) : 0)
        guard let record = ShellResultRecord.text(
            .fileSystemPath, value0: flags, field0: .sequence, field1: .text, field2: .none, source: bytes, count: count
        ) else { truncated = true; return false }
        return append(record)
    }

    public mutating func appendFileSystemInfo(
          kind    : FSKind,
          size    : UInt64,
          blocks  : UInt32,
          created : UInt64,
          modified: UInt64
    ) -> Bool {
        let core = ShellResultRecord.scalar(
            .fileSystemInfo, UInt64(kind.rawValue), size, UInt64(blocks), field0: .fileSystemKind, field1: .byteCount, field2: .blockCount
        )
        let times = ShellResultRecord.scalar(.fileSystemTimes, created, modified, field0: .createdAt, field1: .modifiedAt)
        return append(core) && append(times)
    }

    public mutating func appendFileSystemRead(
        _ bytes: UnsafePointer<UInt8>,
          count: Int,
          first: Bool,
          last : Bool
    ) -> Bool {
        let flags = (first ? UInt64(1) : 0) | (last ? UInt64(2) : 0)
        guard let record = ShellResultRecord.text(
            .fileSystemRead, value0: flags, field0: .sequence, field1: .data, field2: .text, source: bytes, count: count
        ) else { truncated = true; return false }
        return append(record)
    }

    public mutating func appendFileSystemReadTail(
          shown: UInt64,
          total: UInt64
    ) -> Bool {
        append(.scalar(.fileSystemReadTail, shown, total, field0: .byteCount, field1: .blockCount))
    }

    public mutating func appendFileSystemWrite(_ bytes: UInt64) -> Bool {
        append(.scalar(.fileSystemWrite, bytes, field0: .byteCount))
    }

    public mutating func appendFileSystemEmpty() -> Bool {
        append(.scalar(.fileSystemEmpty))
    }

    private mutating func append(_ record: ShellResultRecord) -> Bool {
        guard count < records.count else {
            truncated = true
            return false
        }
        records[count] = record
        count += 1
        return true
    }
}
