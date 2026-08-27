//
//  ShellResultRecord.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public struct ShellResultRecord {
    public let kind     : ShellResultKind
    public let value0   : UInt64
    public let value1   : UInt64
    public let value2   : UInt64
    public let field0   : ShellResultField
    public let field1   : ShellResultField
    public let field2   : ShellResultField
    public let text     : InlineArray<128, UInt8>
    public let textCount: Int

    private init(
        kind     : ShellResultKind,
        value0   : UInt64 = 0,
        value1   : UInt64 = 0,
        value2   : UInt64 = 0,
        field0   : ShellResultField = .none,
        field1   : ShellResultField = .none,
        field2   : ShellResultField = .none,
        text     : InlineArray<128, UInt8> = InlineArray(repeating: 0),
        textCount: Int = 0
    ) {
        self.kind = kind
        self.value0 = value0
        self.value1 = value1
        self.value2 = value2
        self.field0 = field0
        self.field1 = field1
        self.field2 = field2
        self.text = text
        self.textCount = textCount
    }

    static func presentation(_ text: StaticString) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard text.utf8CodeUnitCount <= bytes.count else { return nil }
        for index in 0..<text.utf8CodeUnitCount { bytes[index] = text.utf8Start[index] }
        return ShellResultRecord(
            kind     : .presentation,
            field0   : .text,
            text     : bytes,
            textCount: text.utf8CodeUnitCount
        )
    }

    static func process(
          pid   : UInt64,
          status: UInt32,
          name  : StaticString
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard name.utf8CodeUnitCount <= bytes.count else { return nil }
        for index in 0..<name.utf8CodeUnitCount { bytes[index] = name.utf8Start[index] }
        return ShellResultRecord(
            kind     : .process,
            value0   : pid,
            value1   : UInt64(status),
            field0   : .pid,
            field1   : .processStatus,
            field2   : .programName,
            text     : bytes,
            textCount: name.utf8CodeUnitCount
        )
    }

    static func process(
          pid   : UInt64,
          status: UInt32,
          name  : UnsafePointer<UInt8>,
          count : Int
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard count >= 0, count <= bytes.count else { return nil }
        for index in 0..<count { bytes[index] = name[index] }
        return ShellResultRecord(
            kind     : .process,
            value0   : pid,
            value1   : UInt64(status),
            field0   : .pid,
            field1   : .processStatus,
            field2   : .programName,
            text     : bytes,
            textCount: count
        )
    }

    static func process(
          pid   : UInt64,
          status: UInt32,
          name  : InlineArray<16, UInt8>,
          count : Int
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard count >= 0, count <= name.count else { return nil }
        for index in 0..<count { bytes[index] = name[index] }
        return ShellResultRecord(
            kind     : .process,
            value0   : pid,
            value1   : UInt64(status),
            field0   : .pid,
            field1   : .processStatus,
            field2   : .programName,
            text     : bytes,
            textCount: count
        )
    }

    static func scalar(
        _ kind  : ShellResultKind,
        _ value0: UInt64 = 0,
        _ value1: UInt64 = 0,
        _ value2: UInt64 = 0,
          field0  : ShellResultField = .none,
          field1  : ShellResultField = .none,
          field2  : ShellResultField = .none
    ) -> ShellResultRecord {
        ShellResultRecord(kind: kind, value0: value0, value1: value1, value2: value2, field0: field0, field1: field1, field2: field2)
    }

    public static func truncated() -> ShellResultRecord {
        scalar(.truncated)
    }

    static func processStart(
        _ status: UInt64,
          name  : UnsafePointer<UInt8>,
          count : Int
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard count >= 0, count <= bytes.count else { return nil }
        for index in 0..<count { bytes[index] = name[index] }
        return ShellResultRecord(
            kind     : .processStart,
            value0   : status,
            field0   : .status,
            field1   : .programName,
            text     : bytes,
            textCount: count
        )
    }

    static func text(
        _ kind: ShellResultKind,
          value0: UInt64 = 0,
          value1: UInt64 = 0,
          value2: UInt64 = 0,
          field0: ShellResultField,
          field1: ShellResultField = .none,
          field2: ShellResultField = .text,
          source: UnsafePointer<UInt8>,
          count : Int
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard count >= 0, count <= bytes.count else { return nil }
        for index in 0..<count { bytes[index] = source[index] }
        return ShellResultRecord(
            kind     : kind,
            value0   : value0,
            value1   : value1,
            value2   : value2,
            field0   : field0,
            field1   : field1,
            field2   : field2,
            text     : bytes,
            textCount: count
        )
    }

    static func fileSystemEntry(
          kind : FSKind,
          name : InlineArray<56, UInt8>,
          count: Int
    ) -> ShellResultRecord? {
        var bytes = InlineArray<128, UInt8>(repeating: 0)
        guard count >= 0, count <= name.count else { return nil }
        for index in 0..<count { bytes[index] = name[index] }
        return ShellResultRecord(
            kind     : .fileSystemEntry,
            value0   : UInt64(kind.rawValue),
            field0   : .fileSystemKind,
            field1   : .entryName,
            field2   : .text,
            text     : bytes,
            textCount: count
        )
    }
}
