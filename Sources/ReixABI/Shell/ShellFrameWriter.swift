//
//  ShellFrameWriter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct ShellFrameWriter {
    private let bytes: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private let schema: ShellSchema
    private let sequence: UInt32
    private let flags: ShellFrameFlags
    private var payloadLength = 0
    private var records: UInt16 = 0
    private var invalid = false

    public init?(
        _ bytes: UnsafeMutablePointer<UInt8>,
        capacity: Int,
        schema: ShellSchema,
        sequence: UInt32 = 0,
        flags: ShellFrameFlags = []
    ) {
        guard capacity >= ShellProtocol.headerBytes,
              flags.subtracting(.allowed).isEmpty
        else { return nil }
        self.bytes = bytes
        self.capacity = capacity
        self.schema = schema
        self.sequence = sequence
        self.flags = flags
    }

    public mutating func appendScalar(_ kind: ShellRecordKind, field: ShellField, value: UInt32) -> Bool {
        guard kind == .status || kind == .scalar else { invalid = true; return false }
        guard !invalid, records < ShellProtocol.maximumRecords,
              payloadLength <= ShellProtocol.maximumPayload - ShellProtocol.recordBytes - 4,
              ShellProtocol.headerBytes + payloadLength <= capacity - ShellProtocol.recordBytes - 4
        else { invalid = true; return false }
        let offset = ShellProtocol.headerBytes + payloadLength
        write16(bytes, offset, kind.rawValue)
        write16(bytes, offset + 2, field.rawValue)
        write32(bytes, offset + 4, 4)
        write32(bytes, offset + ShellProtocol.recordBytes, value)
        payloadLength += ShellProtocol.recordBytes + 4
        records += 1
        return true
    }

    public mutating func append(
        _ kind: ShellRecordKind,
        field: ShellField,
        payload: UnsafeRawPointer,
        count: Int
    ) -> Bool {
        guard !invalid, count >= 0, count <= ShellProtocol.maximumPayload,
              records < ShellProtocol.maximumRecords,
              payloadLength <= ShellProtocol.maximumPayload - ShellProtocol.recordBytes - count,
              ShellProtocol.headerBytes + payloadLength <= capacity - ShellProtocol.recordBytes - count
        else { invalid = true; return false }
        let offset = ShellProtocol.headerBytes + payloadLength
        write16(bytes, offset, kind.rawValue)
        write16(bytes, offset + 2, field.rawValue)
        write32(bytes, offset + 4, UInt32(count))
        UnsafeMutableRawPointer(bytes.advanced(by: offset + ShellProtocol.recordBytes)).copyMemory(from: payload, byteCount: count)
        payloadLength += ShellProtocol.recordBytes + count
        records += 1
        return true
    }

    public mutating func appendInPlace(
        _ kind: ShellRecordKind,
        field: ShellField,
        payload: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Bool {
        guard !invalid, count >= 0, count <= ShellProtocol.maximumPayload,
              records < ShellProtocol.maximumRecords,
              payloadLength <= ShellProtocol.maximumPayload - ShellProtocol.recordBytes - count,
              ShellProtocol.headerBytes + payloadLength <= capacity - ShellProtocol.recordBytes - count
        else { invalid = true; return false }
        let offset = ShellProtocol.headerBytes + payloadLength
        guard payload == bytes.advanced(by: offset + ShellProtocol.recordBytes) else {
            invalid = true
            return false
        }
        write16(bytes, offset, kind.rawValue)
        write16(bytes, offset + 2, field.rawValue)
        write32(bytes, offset + 4, UInt32(count))
        payloadLength += ShellProtocol.recordBytes + count
        records += 1
        return true
    }

    public mutating func finish() -> Int {
        guard !invalid, let _ = ShellEnvelope(
            schema: schema,
            sequence: sequence,
            flags: flags,
            recordCount: records,
            payloadLength: UInt16(payloadLength)
        ) else { return 0 }
        write16(bytes, 0, ShellProtocol.version)
        write16(bytes, 2, schema.rawValue)
        write32(bytes, 4, sequence)
        write32(bytes, 8, flags.rawValue)
        write16(bytes, 12, records)
        write16(bytes, 14, UInt16(payloadLength))
        return ShellProtocol.headerBytes + payloadLength
    }
}
