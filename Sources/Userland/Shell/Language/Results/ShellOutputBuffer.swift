//
//  ShellOutputBuffer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public struct ShellOutputBuffer {
    private var bytes = InlineArray<4096, UInt8>(repeating: 0)
    private var count = 0
    public private(set) var overflowed = false
    public private(set) var failed = false

    public init() {}

    public mutating func reset() {
        count = 0
        overflowed = false
        failed = false
    }

    public mutating func invalidate() { failed = true }

    @discardableResult
    public mutating func append(_ byte: UInt8) -> Bool {
        guard !overflowed, count < bytes.count else {
            overflowed = true
            return false
        }
        bytes[count] = byte
        count += 1
        return true
    }

    public mutating func flush(_ send: (UnsafePointer<UInt8>, Int) -> Bool) -> Bool {
        guard !overflowed, !failed else { return false }
        var offset = 0
        while offset < count {
            let amount    = min(TerminalEvent.maximumPayload, count - offset)
            let delivered = bytes.span.withUnsafeBufferPointer { source in
                send(source.baseAddress! + offset, amount)
            }
            guard delivered else {
                let remaining = count - offset
                for index in 0..<remaining { bytes[index] = bytes[offset + index] }
                count = remaining
                return false
            }
            offset += amount
        }
        count = 0
        return true
    }
}
