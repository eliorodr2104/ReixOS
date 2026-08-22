//
//  SerialTransmitQueue.swift
//  ReixOS
//
//  Created by OpenAI Codex on 06/08/2026.
//

struct SerialTransmitQueue {
    static let capacity = 16384

    private static let mask = UInt64(capacity - 1)

    private var storage             = InlineArray<16384, UInt8>(repeating: 0)
    private var head       : UInt64 = 0
    private var tail       : UInt64 = 0
    private var recordStart: UInt64 = 0
    private var recordLimit: Int    = capacity
    private var recording  : Bool   = false
    private var overflowed : Bool   = false

    private(set) var droppedRecords: UInt64 = 0

    var available: Int {
        Self.capacity - Int(head &- tail)
    }

    @discardableResult
    mutating func beginRecord(reserving reservedBytes: Int = 0) -> Bool {
        guard !recording else {
            overflowed = true
            return false
        }

        recordStart = head
        recordLimit = Self.capacity - min(max(reservedBytes, 0), Self.capacity)
        recording = true
        overflowed = false
        return true
    }

    mutating func append(_ byte: UInt8) {
        guard recording, !overflowed else { return }

        guard head &- tail < UInt64(recordLimit) else {
            overflowed = true
            return
        }

        storage[Int(head & Self.mask)] = byte
        head &+= 1
    }

    mutating func append(_ value: StaticString) {
        value.withUTF8Buffer { buffer in
            for byte in buffer { append(byte) }
        }
    }

    @discardableResult
    mutating func endRecord() -> Bool {
        guard recording else { return false }

        recording = false

        if overflowed {
            head = recordStart
            overflowed = false
            droppedRecords &+= 1
            return false
        }

        return true
    }

    mutating func drain(
        budget: Int,
        _ put: (UInt8) -> Bool
    ) -> Int {
        guard budget > 0, !recording else { return 0 }

        var sent = 0

        while sent < budget, tail != head {
            let byte = storage[Int(tail & Self.mask)]
            guard put(byte) else { break }

            tail &+= 1
            sent &+= 1
        }

        return sent
    }
}
