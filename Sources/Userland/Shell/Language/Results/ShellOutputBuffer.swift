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

    /// One frame carries at most this many roles. Output that wants more is
    /// output that has stopped being a list of things.
    public static let spanCapacity = 32

    private var bytes = InlineArray<4096, UInt8>(repeating: 0)
    private var count = 0
    private var spans = InlineArray<32, ReixTextSurfaceStyleSpan?>(repeating: nil)
    private var spanCount = 0
    public private(set) var overflowed = false
    public private(set) var failed = false

    public init() {}

    public mutating func reset() {
        count = 0
        spanCount = 0
        overflowed = false
        failed = false
    }

    /// Where the next byte will land, which is where a stretch begins.
    public var offset: Int { count }

    /// Says what a stretch of what was written means. Roles, never colours:
    /// the backend decides what a container looks like.
    public mutating func mark(
        _ role: ReixTextSurfaceStyleRole,
          from : Int,
          to   : Int
    ) {
        guard to > from, from >= 0, to <= count, spanCount < spans.count,
              let span = ReixTextSurfaceStyleSpan(
                  offset: UInt32(from),
                  length: UInt16(to - from),
                  role: role
              )
        else { return }
        spans[spanCount] = span
        spanCount += 1
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
    public mutating func flush(
        _ send: (UnsafePointer<UInt8>, Int, UnsafePointer<ReixTextSurfaceStyleSpan>?, Int) -> Bool
    ) -> Bool {
        guard !overflowed, !failed else { return false }
        guard count > 0 else { return true }
        var roles = spans
        let delivered = bytes.span.withUnsafeBufferPointer { text in
            roles.span.withUnsafeBufferPointer { marked in
                withUnsafeTemporaryAllocation(
                    of: ReixTextSurfaceStyleSpan.self,
                    capacity: max(1, spanCount)
                ) { ordered in
                    for index in 0..<spanCount { ordered[index] = marked[index]! }
                    return send(
                        text.baseAddress!,
                        count,
                        spanCount == 0 ? nil : UnsafePointer(ordered.baseAddress!),
                        spanCount
                    )
                }
            }
        }
        guard delivered else { return false }
        count = 0
        spanCount = 0
        return true
    }
}
