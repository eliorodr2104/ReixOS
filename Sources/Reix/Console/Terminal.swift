//
//  Terminal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// A terminal: lines in, from wherever they come from.
///
/// The abstraction the shell is written against, and now a client of the
/// terminal server rather than a driver of the serial port. That move is the
/// point of the type existing: the shell's three calls did not change when the
/// hardware moved out from under them, and the shell no longer holds a device
/// capability at all. A program that reads lines has no business mapping
/// registers, exactly as a shell on BSD talks to a tty and not to a UART.
///
/// The line arrives through a page this client owns and grants once, because a
/// reply carries four words and a line carries up to a hundred and twenty-eight
/// bytes. The reply says how many are meaningful.
public struct Terminal {

    /// Longest line the server will assemble. Its editor stops accepting
    /// characters at this point rather than scrolling.
    public static let lineLimit = 128

    private let endpoint: UInt32
    private let page    : UnsafeMutableRawPointer


    /// Registers a page with the terminal server behind `endpoint`.
    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: 1)
        
        guard shared.isValid,
              let mapped = UnsafeMutableRawPointer(
                bitPattern: UInt(shared.address)
              ) else { return nil }

        _ = send(
            handle     : endpoint,
            message    : TerminalOperation.register.message(word0: 1),
            grant      : shared.handle,
            grantRights: [.send, .read, .write]
        )

        let answer = call(
            handle : endpoint,
            message: TerminalOperation.status.message()
        )

        guard TerminalStatus(rawValue: answer.message.words[0]) == .ok else {
            return nil
        }

        self.endpoint = endpoint
        self.page     = mapped
    }


    /// Writes `prompt`, then reads one edited line, blocking until it is
    /// complete.
    ///
    /// Answers how many bytes the line holds, or `-1` when the terminal will not
    /// answer, which is the only failure not worth retrying.
    ///
    /// The prompt goes through the terminal rather than being printed by the
    /// caller, so that it and the echo of what is typed after it come from one
    /// writer. Two writers around the same moment are not ordered.
    public func readLine(
             prompt: StaticString,
        into line  : inout InlineArray<128, UInt8>
    ) -> Int {

        let bytes  = page.assumingMemoryBound(to: UInt8.self)
        let length = min(prompt.utf8CodeUnitCount, Self.lineLimit)

        for index in 0..<length { bytes[index] = prompt.utf8Start[index] }

        let answer = call(
            handle : endpoint,
            message: TerminalOperation.readLine.message(word0: UInt32(length))
        )

        let count = answer.message.words[0]
        guard count != UInt32.max, Int(count) <= Self.lineLimit else {
            return -1
        }

        for index in 0..<Int(count) { line[index] = bytes[index] }

        return Int(count)
    }
}
