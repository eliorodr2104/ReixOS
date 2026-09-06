//
//  ShellOutputBuffer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/08/2026.
//

import ReixABI

public struct ShellOutputBuffer {
    /// Small enough that one flush is always one frame, so a scalar can never be
    /// split across two of them and output never arrives half-styled.
    public static let capacity = 4096

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

    /// Hands the whole buffer over in one frame. What the receiver refuses stays
    /// buffered exactly as it was, so a refusal costs one retry.
    public mutating func flush(_ send: (UnsafePointer<UInt8>, Int) -> Bool) -> Bool {
        guard !overflowed, !failed else { return false }
        guard count > 0 else { return true }
        let delivered = bytes.span.withUnsafeBufferPointer { send($0.baseAddress!, count) }
        guard delivered else { return false }
        count = 0
        return true
    }
}
