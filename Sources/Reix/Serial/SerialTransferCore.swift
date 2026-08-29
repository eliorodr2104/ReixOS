//
//  SerialTransferCore.swift
//  ReixOS
//

import ReixABI

/// The fixed pending transmit state shared by SerialServer and the host harness.
public struct SerialTransferCore {
    private var pending: ReixSerialChunk?
    private var offset = 0

    public init() {}

    public var hasPending: Bool { pending != nil }

    /// Tries at most `budget` bytes. The sink returns false when its FIFO is full.
    public mutating func transfer(
        next: () -> ReixSerialRingPop,
        isEmpty: () -> Bool,
        budget: Int,
        sink: (UInt8) -> Bool
    ) -> ReixSerialStatus {
        guard budget > 0 else { return hasPending ? .pending : .ok }
        var remaining = budget
        while remaining > 0 {
            if pending == nil {
                switch next() {
                    case .chunk(let chunk):
                        guard chunk.direction == .transmit else { return .malformed }
                        pending = chunk
                        offset = 0
                    case .status(let status):
                        return status == .empty ? .ok : status
                }
            }
            guard let chunk = pending else { return .ok }
            guard offset < chunk.count else {
                pending = nil
                offset = 0
                continue
            }
            guard sink(chunk.payload[offset]) else { return .pending }
            offset += 1
            remaining -= 1
            if offset == chunk.count {
                pending = nil
                offset = 0
            }
        }
        return pending == nil && isEmpty() ? .ok : .pending
    }
}
