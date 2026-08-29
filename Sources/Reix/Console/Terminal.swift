//
//  Terminal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// A terminal: structured input events and render patches over IPC.
///
/// The abstraction the shell is written against, and now a client of the
/// terminal server rather than a driver of the serial port. The shell no longer
/// holds a device capability or decodes hardware bytes. A program that reads
/// input has no business mapping registers, exactly as a shell on BSD talks to
/// a tty and not to a UART.
///
/// Events and patches travel through a page this client owns and grants once;
/// the reply words carry status, sequence, length and attachment token.
///
/// **Noncopyable, because it owns two things a copy would own twice.** A page and
/// the capability naming it are resources, and this type is now the only place
/// that knows about them: a copy would be a second owner of one region, and there
/// was no owner at all before - the page was created, granted, and then never
/// released by anybody, including on the path where registration failed. `deinit`
/// is what makes "the terminal went away" cost nothing.
public struct Terminal: ~Copyable {

    /// Maximum shell source/presentation payload retained by compatibility APIs.
    public static let lineLimit = 256

    private static let pageSize: UInt64 = 4096

    private static let prefix = ShellProtocol.headerBytes + ShellProtocol.recordBytes

    private let endpoint: UInt32

    /// The page the line arrives in, the capability that names it, and how far it
    /// reaches.
    ///
    /// All three because all three are needed to give it back, and giving back
    /// only part of it leaves the region alive: dropping the capability does not
    /// unmap the page, unmapping does not free it while a capability still names
    /// it, and unmapping the wrong length unmaps the wrong thing. The extent is
    /// stored rather than recomputed so that `deinit` releases what was really
    /// created and not what a constant says should have been.
    private let handle  : UInt32
    private let address : UInt64
    private let extent  : UInt64
    private let token   : UInt32
    private var sequence: UInt32 = 0

    private var bytes: UnsafeMutablePointer<UInt8> {
        UnsafeMutableRawPointer(bitPattern: UInt(address))!
            .assumingMemoryBound(to: UInt8.self)
    }

    /// Registers a page with the terminal server behind `endpoint`.
    ///
    /// Every way out gives the page back. It used to leave one shared region and
    /// one capability behind per attempt, on precisely the path taken when
    /// something has already gone wrong.
    public init?(endpoint: UInt32) {
        let shared = shmCreate(pageCount: 1)

        guard shared.isValid,
              UnsafeMutableRawPointer(bitPattern: UInt(shared.address)) != nil
        else { return nil }

        func giveUp() {
            _ = munmap(addr: shared.address, size: Self.pageSize)
            _ = capDrop(shared.handle)
        }

        guard shared.handle != 0 else { giveUp(); return nil }
        _ = send(
            handle     : endpoint,
            message    : TerminalOperation.register.message(word0: 1, word1: shared.handle),
            grant      : shared.handle,
            grantRights: [.send, .read, .write]
        )

        guard case .success(let answer) = call(
            handle : endpoint,
            message: TerminalOperation.status.message(word0: shared.handle)
        ),
        answer.message.tag.length == 2,
        TerminalStatus(rawValue: answer.message.words[0]) == .ok,
        answer.message.words[1] == shared.handle
        else { giveUp(); return nil }

        self.endpoint = endpoint
        self.handle   = shared.handle
        self.address  = shared.address
        self.extent   = Self.pageSize
        self.token    = shared.handle
    }


    deinit {
        _ = munmap(addr: address, size: extent)
        _ = capDrop(handle)
    }

    /// Reads one protocol-owned key event. Escape bytes and UART details end at
    /// the terminal server; editing remains in the shell process.
    public mutating func readInput() -> TerminalInputEvent? {
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        let current = sequence
        guard case .success(let answer) = call(
            handle: endpoint,
            message: terminalMessage(sequence: current, length: 0)
        ), answer.message.tag.label == TerminalOperation.readLine.rawValue,
           answer.message.tag.length == 4,
           TerminalStatus(rawValue: answer.message.words[0]) == .ok,
           answer.message.words[1] == current,
           answer.message.words[3] == token
        else { return nil }
        let length = Int(answer.message.words[2])
        guard length >= TerminalInputEvent.headerBytes, length <= Int(extent) else { return nil }
        guard let event = TerminalInputEvent.decode(UnsafePointer(bytes), length: length),
              current != 0, event.sequence == current
        else { return nil }
        return event
    }

    public mutating func present(_ patch: TerminalRenderPatch) -> Bool {
        let length = patch.encode(into: bytes, capacity: Int(extent))
        guard length > 0,
              case .success(let answer) = call(
                handle: endpoint,
                message: terminalMessage(.present, sequence: patch.sequence, length: UInt32(length))
              ), answer.message.tag.label == TerminalOperation.present.rawValue,
              answer.message.tag.length == 4,
              TerminalStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == patch.sequence,
              answer.message.words[2] == UInt32(length),
              answer.message.words[3] == token
        else { return false }
        return true
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
    public mutating func readLine(
             prompt: StaticString,
        into line  : inout InlineArray<128, UInt8>
    ) -> Int {

        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        let currentSequence = sequence

        let length = encodePresentation(
            sequence: currentSequence,
            payload : UnsafeRawPointer(prompt.utf8Start),
            count   : min(prompt.utf8CodeUnitCount, Self.lineLimit)
        )
        guard length > 0 else { return -1 }

        guard case .success(let answer) = call(
            handle : endpoint,
            message: terminalMessage(sequence: currentSequence, length: UInt32(length))

        ), answer.message.tag.label == TerminalOperation.readLine.rawValue,
           answer.message.tag.length == 4,
           TerminalStatus(rawValue: answer.message.words[0]) == .ok,
           answer.message.words[1] == currentSequence,
           answer.message.words[3] == token
        else { return -1 }

        let eventLength = Int(answer.message.words[2])
        guard eventLength >= TerminalEvent.headerBytes,
              eventLength <= Int(extent),
              let event = TerminalEvent.decode(
                UnsafePointer(bytes),
                length: eventLength
              )
        else { return -1 }

        if event.kind == .interrupt,
           event.sequence == currentSequence,
           event.status == .cancelled {
            // Cancellation is a new empty prompt, not EOF and not a command.
            return 0
        }

        guard event.kind == .line,
              TerminalAcknowledgement(
                sequence: currentSequence,
                count   : event.count,
                status  : .ok
              ).accepts(event)
        else { return -1 }

        for index in 0..<event.count {
            line[index] = event.payload[index]
        }

        return event.count
    }

    public mutating func present(
        _ fill: (UnsafeMutablePointer<UInt8>, Int) -> Int
    ) -> Bool {

        sequence &+= 1
        if sequence == 0 { sequence = 1 }

        let count = fill(
            bytes.advanced(by: Self.prefix),
            min(TerminalEvent.maximumPayload, Int(extent) - Self.prefix)
        )

        guard count >= 0, count <= TerminalEvent.maximumPayload else {
            return false
        }

        let length = encodePresentationInPlace(
            sequence: sequence,
            count   : count
        )

        guard length > 0,
              case .success(let answer) = call(
                handle: endpoint,
                message: terminalMessage(.present, sequence: sequence, length: UInt32(length))
              ),
              answer.message.tag.label == TerminalOperation.present.rawValue,
              answer.message.tag.length == 4,
              TerminalStatus(rawValue: answer.message.words[0]) == .ok,
              answer.message.words[1] == sequence,
              answer.message.words[2] == UInt32(length),
              answer.message.words[3] == token
        else { return false }

        return true
    }

    private func encodePresentation(
        sequence: UInt32,
        payload : UnsafeRawPointer,
        count   : Int
    ) -> Int {

        guard var writer = ShellFrameWriter(
            bytes,
            capacity: Int(extent),
            schema  : .presentation,
            sequence: sequence,
            flags   : []

        ), writer.append(.text, field: .text, payload: payload, count: count)
        else { return 0 }

        return writer.finish()
    }

    private func encodePresentationInPlace(
        sequence: UInt32,
        count   : Int
    ) -> Int {

        let payload = bytes.advanced(
            by: ShellProtocol.headerBytes + ShellProtocol.recordBytes
        )

        guard var writer = ShellFrameWriter(
            bytes,
            capacity: Int(extent),
            schema  : .presentation,
            sequence: sequence,
            flags   : []
        ), writer.appendInPlace(.text, field: .text, payload: payload, count: count)
        else { return 0 }

        return writer.finish()
    }

    @inline(__always)
    private func terminalMessage(
        _ operation: TerminalOperation = .readLine,
          sequence : UInt32,
          length   : UInt32
    ) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = sequence
        words[1] = length
        words[2] = token
        return Message(
            tag  : MessageTag(operation, length: 3),
            words: words
        )
    }
}
