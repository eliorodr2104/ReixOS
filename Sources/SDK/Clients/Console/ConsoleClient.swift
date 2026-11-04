//
//  ConsoleClient.swift
//  ReixOS
//
//  Created by Eliomar on 29/06/2026.
//

import ReixABI

public struct ConsoleClient {

    /// The ring is exactly one page, and the server hard-codes that size:
    /// `shmMap` returns an address and no length, so the two sides can only agree
    /// on the region size by contract.
    private static let pageSize : Int    = 4096
    private static let ringPages: UInt32 = 1
    private static let newLine  : UInt8  = UInt8(ascii: "\n")

    /// How many times `write` asks the server to drain a full ring before giving
    /// up on the ring for that byte. Unbounded retries used to be a livelock: a
    /// registration the server dropped means nothing ever drains, and `push`
    /// never succeeds again.
    private static let flushAttempts = 4

    private let endpoint: UInt32
    private let ring    : Ring

    /// Coalesces the bytes of a printed line so they reach the ring through
    /// one `push(_:count:)` instead of one `push(_:)`, and one `dmb ish`, per
    /// character: `print` drives `write` a byte at a time, and this is the
    /// only place that run of calls can be batched back together.
    ///
    /// Static rather than a stored property: `Console.client` hands out a
    /// fresh copy of `ConsoleClient` on every call, so state that has to
    /// survive between one `write` and the next cannot live on `self`.
    private enum Stage {

        /// `InlineArray`'s length has to be a literal, not this `static let`:
        /// only the count comparisons below can use the named constant.
        static let capacity = 128

        nonisolated(unsafe) static var bytes = InlineArray<128, UInt8>(repeating: 0)
        nonisolated(unsafe) static var count = 0

        static var isFull: Bool { count == capacity }

        static func reset() { count = 0 }

        static func append(_ byte: UInt8) {
            bytes[count] = byte
            count += 1
        }

        /// Hands the staged run to `body` as one contiguous pointer. The body
        /// reports how much it durably accepted; a refused suffix stays staged
        /// in order, so retrying can neither lose nor duplicate bytes.
        static func drain(_ body: (UnsafeRawPointer, Int) -> Int) -> Bool {
            guard count > 0 else { return true }

            let original = count
            let accepted = withUnsafeTemporaryAllocation(
                of: UInt8.self,
                capacity: original
            ) { contiguous in
                for index in 0..<original { contiguous[index] = bytes[index] }
                return body(UnsafeRawPointer(contiguous.baseAddress!), original)
            }
            guard accepted >= 0, accepted <= original else { return false }
            if accepted == original {
                count = 0
                return true
            }
            guard accepted > 0 else { return false }
            for index in accepted..<original {
                bytes[index - accepted] = bytes[index]
            }
            count = original - accepted
            return false
        }
    }

    public init?(console endpoint: UInt32) {

        let shm = shmCreate(pageCount: UInt64(Self.ringPages))

        guard shm.isValid, let base = UnsafeMutableRawPointer(
            bitPattern: UInt(shm.address)
        ) else { return nil }


        self.endpoint = endpoint
        self.ring     = Ring(
            base      : base,
            regionSize: Self.pageSize
        )
        Stage.reset()
        self.ring.reset()

        send(
            handle     : endpoint,
            message    : ConsoleOperation.register.message(word0: Self.ringPages),
            grant      : shm.handle,
            grantRights: [.send, .read, .write]
        )


        guard flushed() else { return nil }
    }

    /// Compatibility writers preserve line visibility by notifying the server
    /// when a newline closes. Scene backends use `writeBuffered` and publish one
    /// whole presentation with `flushNow`, avoiding one IPC notification per
    /// displayed line.
    public func write(_ byte: UInt8) -> ConsoleWrite {
        write(byte, notifyOnNewline: true)
    }

    public func writeBuffered(_ byte: UInt8) -> ConsoleWrite {
        write(byte, notifyOnNewline: false)
    }

    private func write(
        _ byte         : UInt8,
        notifyOnNewline: Bool
    ) -> ConsoleWrite {
        if Stage.isFull {
            let result = flushStage()
            guard result == .accepted else { return result }
            let drain = requestPartialDrain()
            guard drain == .accepted else { return drain }
        }
        Stage.append(byte)

        if notifyOnNewline, byte == Self.newLine {
            let result = flushStage()
            guard result == .accepted else { return result }
            guard send(handle: endpoint, message: ConsoleOperation.kick.message()).isDelivered
            else { return .unregistered }
        }
        return .accepted
    }

    /// Pushes whatever is staged and asks the server to drain it now, without
    /// waiting for the newline that normally closes a line.
    ///
    /// For the one writer that has to be seen before its line ends: a terminal
    /// echoing keystrokes. Everything else is better off staged, which is why
    /// this is a call and not the default.
    @discardableResult
    public func flushNow() -> Bool {
        guard flushStage() == .accepted else { return false }
        return requestPartialDrain() == .accepted
    }

    /// Transfers ownership of queued bytes without waiting for the physical
    /// UART to become empty. VTAdapter also serves input, so making a scene ack
    /// wait for PL011 would serialize Backspace and Submit behind screen output.
    private func requestPartialDrain() -> ConsoleWrite {
        send(
            handle : endpoint,
            message: ConsoleOperation.drainPartial.message()
        ).isDelivered ? .accepted : .unregistered
    }


    /// Pushes every staged byte into the ring in as few `push(_:count:)`
    /// calls as its free contiguous space allows: one call when the ring has
    /// room for the whole run, more only when it has to ask the server to
    /// drain in between.
    ///
    /// A refused suffix remains in `Stage`. Falling through to the kernel here
    /// would bypass VTAdapter, reorder the stream, and recreate the second
    /// presentation path that TextSurface is meant to eliminate.
    private func flushStage() -> ConsoleWrite {
        var outcome  = ConsoleWrite.accepted
        let complete = Stage.drain { pending, count in

            var offset = ring.push(pending, count: count)

            while offset < count {

                var progressed = false

                for _ in 0..<Self.flushAttempts {

                    guard let status = flushStatus() else {
                        outcome = .unregistered
                        return offset
                    }
                    guard status == .registered || status == .pending else {
                        outcome = .unregistered
                        return offset
                    }

                    let accepted = ring.push(pending + offset, count: count - offset)

                    if accepted > 0 {
                        offset     += accepted
                        progressed  = true
                        break
                    }
                }

                guard progressed else {
                    outcome = .backpressure
                    return offset
                }
            }
            return offset
        }
        return complete ? .accepted : outcome
    }

    /// Asks the server to drain, and answers whether it still holds a ring for
    /// this client.
    ///
    /// A call that did not happen answers `false`, which is the safe direction
    /// and the honest one: a server that cannot be reached is not draining, so
    /// waiting for room in the ring would be waiting for nobody.
    private func flushed() -> Bool {

        guard let status = flushStatus() else { return false }
        return status == .registered || status == .pending
    }

    private func flushStatus() -> ConsoleStatus? {

        guard case .success(let response) = call(
            handle : endpoint,
            message: ConsoleOperation.flush.message()
        ) else { return nil }

        guard response.message.tag.length >= 1 else { return nil }

        return ConsoleStatus(rawValue: response.message.words[0])
    }

}

/// Publishes one complete presentation to ConsoleServer. The acknowledgement
/// reports that the server owns the queued bytes; the physical UART may still
/// be draining, and its backpressure leaves the scene valid.
@inline(__always)
@discardableResult
public func consoleFlush() -> Bool {
    Console.client?.flushNow() ?? false
}

/// Scene backends batch newlines and notify ConsoleServer once per presentation.
/// Returning `false` is fail-closed: callers must not commit their semantic
/// screen state when the transport refused part of the VT transaction.
@inline(__always)
@discardableResult
public func consoleWriteBuffered(_ byte: UInt8) -> Bool {
    guard let client = Console.client else { return false }
    switch client.writeBuffered(byte) {
        case .accepted: return true
        case .backpressure: return false
        case .unregistered:
            Console.client = nil
            return false
    }
}


@_cdecl("putchar")
public func putchar(ch: UInt8) {

    guard let client = Console.client else {
        _ = _syscall(.putchar, UInt64(ch))
        return
    }

    switch client.write(ch) {
        case .accepted: break

        case .backpressure: break

        case .unregistered:
            Console.client = nil
    }
}
