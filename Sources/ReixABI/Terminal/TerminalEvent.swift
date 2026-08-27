//
//  TerminalEvent.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

public struct TerminalEvent {
    public static let headerBytes = 16
    public static let maximumPayload = 128
    public let kind: TerminalEventKind
    public let sequence: UInt32
    public let flags: TerminalEventFlags
    public let status: TerminalEventStatus
    public let count: Int
    public let payload: InlineArray<128, UInt8>

    private init(kind: TerminalEventKind, sequence: UInt32, flags: TerminalEventFlags, status: TerminalEventStatus, count: Int, payload: InlineArray<128, UInt8>) {
        self.kind = kind
        self.sequence = sequence
        self.flags = flags
        self.status = status
        self.count = count
        self.payload = payload
    }

    public static func line(sequence: UInt32, bytes: UnsafePointer<UInt8>, count: Int) -> TerminalEvent {
        var payload = InlineArray<128, UInt8>(repeating: 0)
        let accepted = count >= 0 && count <= maximumPayload
        if accepted {
            for index in 0..<count { payload[index] = bytes[index] }
        }
        return TerminalEvent(
            kind: .line,
            sequence: sequence,
            flags: accepted ? [] : [.error],
            status: accepted ? .ok : .malformed,
            count: accepted ? count : 0,
            payload: payload
        )
    }

    public static func eof(sequence: UInt32) -> TerminalEvent {
        TerminalEvent(kind: .eof, sequence: sequence, flags: [.end], status: .ok, count: 0, payload: InlineArray(repeating: 0))
    }

    /// Ctrl-C is an input event, not a byte injected into the shell language.
    /// The receiver can discard its current edit without treating cancellation
    /// as EOF or executing a partial command.
    public static func interrupted(sequence: UInt32) -> TerminalEvent {
        TerminalEvent(kind: .interrupt, sequence: sequence, flags: [.cancelled], status: .cancelled, count: 0, payload: InlineArray(repeating: 0))
    }

    public func encode(into bytes: UnsafeMutablePointer<UInt8>, capacity: Int) -> Int {
        guard count >= 0, count <= Self.maximumPayload,
              capacity >= Self.headerBytes + count,
              flags.subtracting(.allowed).isEmpty,
              Self.isCoherent(kind: kind, status: status, flags: flags, count: count)
        else { return 0 }
        write16(bytes, 0, ShellProtocol.version)
        write16(bytes, 2, kind.rawValue)
        write32(bytes, 4, sequence)
        write32(bytes, 8, flags.rawValue)
        write16(bytes, 12, UInt16(count))
        write16(bytes, 14, status.rawValue)
        for index in 0..<count { bytes[Self.headerBytes + index] = payload[index] }
        return Self.headerBytes + count
    }

    public static func decode(_ bytes: UnsafePointer<UInt8>, length: Int) -> TerminalEvent? {
        guard length >= Self.headerBytes,
              read16(bytes, 0) == ShellProtocol.version,
              let kind = TerminalEventKind(rawValue: read16(bytes, 2)),
              let status = TerminalEventStatus(rawValue: read16(bytes, 14)),
              let flags = checkedTerminalFlags(read32(bytes, 8))
        else { return nil }
        let count = Int(read16(bytes, 12))
        guard count <= Self.maximumPayload,
              length == Self.headerBytes + count,
              Self.isCoherent(kind: kind, status: status, flags: flags, count: count)
        else { return nil }
        var payload = InlineArray<128, UInt8>(repeating: 0)
        for index in 0..<count { payload[index] = bytes[Self.headerBytes + index] }
        return TerminalEvent(kind: kind, sequence: read32(bytes, 4), flags: flags, status: status, count: count, payload: payload)
    }

    private static func isCoherent(
        kind: TerminalEventKind,
        status: TerminalEventStatus,
        flags: TerminalEventFlags,
        count: Int
    ) -> Bool {
        switch kind {
            case .line:
                switch status {
                    case .ok:
                        return flags.isEmpty
                    case .malformed, .refused:
                        return count == 0 && flags == [.error]
                    case .cancelled:
                        return count == 0 && flags == [.cancelled]
                }

            case .eof:
                return status == .ok && flags == [.end] && count == 0

            case .interrupt:
                return status == .cancelled && flags == [.cancelled] && count == 0

            // Resizing needs its own fixed geometry schema; accepting a
            // zero-byte placeholder would turn malformed terminal state into a
            // presentation decision, so it remains fail-closed for now.
            case .resize:
                return false
        }
    }
}
