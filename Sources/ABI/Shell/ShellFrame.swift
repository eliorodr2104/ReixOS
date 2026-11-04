//
//  ShellFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct ShellFrame {

    public let envelope: ShellEnvelope
    private let bytes  : UnsafePointer<UInt8>
    private let length : Int

    public var recordCount: Int { Int(envelope.recordCount) }

    private init(
        _ envelope: ShellEnvelope,
          bytes   : UnsafePointer<UInt8>,
          length  : Int
    ) {
        self.envelope = envelope
        self.bytes    = bytes
        self.length   = length
    }

    public static func decode(
        _ bytes : UnsafePointer<UInt8>,
          length: Int
    ) -> ShellFrame? {

        guard length >= ShellProtocol.headerBytes else { return nil }

        let version = read16(bytes, 0)
        guard version == ShellProtocol.version,
              let schema = ShellSchema(rawValue: read16(bytes, 2)),
              let envelope = ShellEnvelope(
                version      : version,
                schema       : schema,
                sequence     : read32(bytes, 4),
                flags        : ShellFrameFlags(rawValue: read32(bytes, 8)),
                recordCount  : read16(bytes, 12),
                payloadLength: read16(bytes, 14)
              )
        else { return nil }

        let (total, overflow) = ShellProtocol.headerBytes.addingReportingOverflow(
            Int(envelope.payloadLength)
        )

        guard !overflow, total == length else { return nil }

        var offset = ShellProtocol.headerBytes
        for _ in 0..<Int(envelope.recordCount) {

            guard offset <= total - ShellProtocol.recordBytes,
                  ShellRecordKind(rawValue: read16(bytes, offset)) != nil,
                  ShellField(rawValue: read16(bytes, offset + 2)) != nil
            else { return nil }

            let payload = Int(read32(bytes, offset + 4))
            let (next, overflow) = (offset + ShellProtocol.recordBytes).addingReportingOverflow(payload)

            guard !overflow, next <= total else { return nil }

            offset = next
        }

        guard offset == total else { return nil }
        return ShellFrame(envelope, bytes: bytes, length: length)
    }

    public func scalar(at index: Int) -> ShellScalar? {

        guard index >= 0, index < recordCount else { return nil }

        var offset = ShellProtocol.headerBytes
        for record in 0..<recordCount {

            guard offset <= length - ShellProtocol.recordBytes,
                  let kind = ShellRecordKind(rawValue: read16(bytes, offset)),
                  let field = ShellField(rawValue: read16(bytes, offset + 2))
            else { return nil }

            let payload = Int(read32(bytes, offset + 4))
            let start = offset + ShellProtocol.recordBytes

            guard start <= length, payload <= length - start else { return nil }

            if record == index {
                guard (kind == .status || kind == .scalar), payload == 4 else { return nil }
                return ShellScalar(kind: kind, field: field, value: read32(bytes, start))
            }

            offset = start + payload
        }

        return nil
    }

    public func text(at index: Int) -> ShellTextSpan? {

        guard index >= 0, index < recordCount else { return nil }

        var offset = ShellProtocol.headerBytes
        for record in 0..<recordCount {

            guard offset <= length - ShellProtocol.recordBytes,
                  let kind = ShellRecordKind(rawValue: read16(bytes, offset)),
                  let field = ShellField(rawValue: read16(bytes, offset + 2))
            else { return nil }

            let payload = Int(read32(bytes, offset + 4))
            let start = offset + ShellProtocol.recordBytes

            guard start <= length, payload <= length - start else { return nil }

            if record == index {
                guard kind == .text, field == .text else { return nil }
                return ShellTextSpan(bytes: bytes + start, count: payload)
            }

            offset = start + payload
        }

        return nil
    }
}
