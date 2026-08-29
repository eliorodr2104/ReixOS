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

        static func append(_ byte: UInt8) {
            bytes[count] = byte
            count += 1
        }

        /// Hands the staged run to `body` as one contiguous pointer and
        /// empties the stage, whatever `body` does with it.
        static func drain(_ body: (UnsafeRawPointer, Int) -> Void) {
            guard count > 0 else { return }

            withUnsafeMutablePointer(to: &bytes) { ptr in
                body(UnsafeRawPointer(ptr), count)
            }

            count = 0
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
        self.ring.reset()

        send(
            handle     : endpoint,
            message    : ConsoleOperation.register.message(word0: Self.ringPages),
            grant      : shm.handle,
            grantRights: [.send, .read, .write]
        )


        guard flushed() else { return nil }
    }

    /// Stages `byte` instead of pushing it alone, and only touches the ring
    /// once a line closes or the stage fills up: everything in between is a
    /// plain array write, not a `push(_:)` and not a `dmb ish`.
    ///
    /// The byte that closes the stage (the newline, or whichever byte finds
    /// the stage full) still goes through the original single-byte path
    /// below unchanged, so its outcome, and the kick that follows a newline,
    /// are reported exactly as before.
    public func write(_ byte: UInt8) -> ConsoleWrite {

        if byte == Self.newLine || Stage.isFull {
            flushStage()

        } else {
            Stage.append(byte)
            return .accepted
        }

        if !ring.push(byte) {
            let result = drainAndRetry(byte)
            guard result == .accepted else { return result }
        }

        if byte == Self.newLine {
            send(
                handle : endpoint,
                message: ConsoleOperation.kick.message()
            )
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
        flushStage()

        // `drainPartial` and not `kick`: the console emits whole lines, and a
        // prompt or an echoed character is not one. Without this the bytes sit
        // in the ring until something closes the line, which for a terminal
        // waiting at a prompt is never.
        guard send(
            handle : endpoint,
            message: ConsoleOperation.drainPartial.message()

        ).isDelivered else { return false }

        return flushed()
    }


    /// Pushes every staged byte into the ring in as few `push(_:count:)`
    /// calls as its free contiguous space allows: one call when the ring has
    /// room for the whole run, more only when it has to ask the server to
    /// drain in between.
    ///
    /// Bytes that still do not fit after `flushAttempts` retries, or whose
    /// registration is gone, fall back to the same raw `.putchar` syscall a
    /// single byte uses under backpressure, so nothing staged is ever lost.
    /// Always empties the stage, whichever path it took.
    private func flushStage() {

        Stage.drain { pending, count in

            var offset = ring.push(pending, count: count)

            while offset < count {

                var progressed = false

                for _ in 0..<Self.flushAttempts {

                    guard flushed() else {
                        Self.fallback(pending, from: offset, count: count)
                        return
                    }

                    let accepted = ring.push(pending + offset, count: count - offset)

                    if accepted > 0 {
                        offset     += accepted
                        progressed  = true
                        break
                    }
                }

                guard progressed else {
                    Self.fallback(pending, from: offset, count: count)
                    return
                }
            }
        }
    }

    /// Slow path for a full ring: ask the server to drain and retry, a bounded
    /// number of times.
    ///
    /// The reply doubles as a liveness check, which is what separates real
    /// backpressure from a registration the server dropped, in the latter case
    /// draining is a no-op and retrying would never terminate.
    private func drainAndRetry(_ byte: UInt8) -> ConsoleWrite {

        for _ in 0..<Self.flushAttempts {

            guard flushed() else { return .unregistered }

            if ring.push(byte) { return .accepted }
        }

        return .backpressure
    }

    /// Asks the server to drain, and answers whether it still holds a ring for
    /// this client.
    ///
    /// A call that did not happen answers `false`, which is the safe direction
    /// and the honest one: a server that cannot be reached is not draining, so
    /// waiting for room in the ring would be waiting for nobody. The caller
    /// falls back to printing through the kernel.
    private func flushed() -> Bool {

        guard case .success(let response) = call(
            handle : endpoint,
            message: ConsoleOperation.flush.message()
        ) else { return false }

        guard response.message.tag.length >= 1 else { return false }

        return ConsoleStatus(rawValue: response.message.words[0]) == .registered
    }

    /// Emits `pending[from..<count]` one byte at a time through the raw
    /// `.putchar` syscall, the same fallback a single byte takes.
    private static func fallback(_ pending: UnsafeRawPointer, from: Int, count: Int) {
        let bytes = pending.assumingMemoryBound(to: UInt8.self)
        for i in from..<count {
            _syscall(.putchar, UInt64(bytes[i]))
        }
    }
}

/// Makes everything written so far visible and confirms ConsoleServer retained
/// the caller ring. A direct kernel-console path cannot provide that receipt.
@inline(__always)
@discardableResult
public func consoleFlush() -> Bool {
    Console.client?.flushNow() ?? false
}


@_cdecl("putchar")
public func putchar(ch: UInt8) {

    guard let client = Console.client else {
        _ = _syscall(.putchar, UInt64(ch))
        return
    }

    switch client.write(ch) {
        case .accepted: break

        case .backpressure:
            _syscall(.putchar, UInt64(ch))

        case .unregistered:
            Console.client = nil
            _syscall(.putchar, UInt64(ch))
    }
}
