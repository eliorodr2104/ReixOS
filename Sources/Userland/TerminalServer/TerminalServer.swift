//
//  TerminalServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// Owns the keyboard and turns device bytes into semantic terminal events.
///
/// Escape decoding and rendering are terminal concerns. Editing, history and
/// parser completeness live in the shell; IPC between them contains versioned
/// event and patch records rather than keyboard or screen byte streams.
///
/// **One reader at a time, on purpose.** A pending input-event request waits for
/// the keyboard interrupt, so a second reader queues behind the first. The
/// registered shared page and its epoch/token fence make that ownership
/// explicit.
///
/// It holds the serial window and the interrupt line, and nothing else holds
/// them. A shell that wanted to read the keyboard directly could not: it has no
/// device capability to map.
public struct TerminalServer: Service {

    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint : UInt32
    private let uartBase : UnsafeMutableRawPointer
    private let interrupt: UInt32
    #if REIX_TERMINAL_PROFILE
    private let profileMarker: UInt32
    #endif

    /// The one registered reader.
    ///
    /// One value where there were two independent fields, a badge and a pointer,
    /// assigned one after the other. Registering twice replaced both and released
    /// neither, so every registration after the first cost this process a mapped
    /// page and a capability for the rest of the boot - and in between the two
    /// assignments there was a moment where the badge was the new reader's and the
    /// page was the old one's. See `ShmAttachment.Slot`.
    private var reader = ShmAttachment.Slot()

    private static let pageSize: UInt64 = 4096

    /// How many pages a reader may grant. Exactly one: protocol events and
    /// render patches are bounded to a fraction of a page.
    private static let readerPages: UInt32 = 1
    private static let maximumTraceValue: UInt32 = 0x00FF_FFFF

    /// Lines the kernel delivered and masked, owed back after the device is
    /// serviced.
    private var delivered: UInt64 = 0

    public var serviceEndpoint: UInt32 { endpoint }

    #if REIX_TERMINAL_PROFILE
    @inline(__always)
    private func mark(
        _ point    : InteractionTracePoint,
        correlation: UInt32,
        value      : UInt32
    ) {
        guard let mark = InteractionTraceMark(point: point, correlation: correlation, value: value) else { return }
        profileInteractionMark(mark, authority: profileMarker)
    }
    #endif


    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint = endpoint

        guard let device = environment.device, let interrupt = environment.interrupt else {
            print("[ SERVE ] Terminal Server has no terminal capabilities")
            exit(code: 1)
        }
        #if REIX_TERMINAL_PROFILE
        guard let profileMarker = environment.profileMarker else {
            print("[ SERVE ] Terminal Server has no profile marker")
            exit(code: 1)
        }
        self.profileMarker = profileMarker
        #endif

        guard let mapped = UnsafeMutableRawPointer(
            bitPattern: UInt(mapDevice(handle: device))
        ) else {
            print("[ SERVE ] Terminal Server cannot map the serial window")
            exit(code: 1)
        }

        self.uartBase  = mapped
        self.interrupt = interrupt

        pl011EnableReceive(mapped)

        print("[ SERVE ] Terminal Server running")
    }


    public mutating func handle(
        _ operation: TerminalOperation,
          request  : inout ReceivedMessage
    ) {
        // A reader that has gone is let go before anything is decided, so a dead
        // one neither holds this server's page nor keeps a live process from
        // registering. It used to hold both for the rest of the boot.
        sweepDeadReader()

        switch operation {
            case .register: register(&request)
            case .status  : status(&request)
            case .readLine: readLine(&request)
            case .present : present(&request)
        }
    }


    /// Lets the registered reader go if it is no longer running.
    private mutating func sweepDeadReader() {

        guard let held = reader.current, !identityAlive(held.identity) else { return }

        _ = reader.take()
        surrender(held)
    }


    /// Gives a window and its capability back.
    ///
    /// Unmapped before the capability is dropped, and both are needed: dropping a
    /// capability does not take the window out of this address space, and the
    /// area holds a reference of its own.
    private func surrender(_ attachment: ShmAttachment) {
        _ = munmap(addr: attachment.address, size: attachment.extent)
        _ = capDrop(attachment.grant)
    }


    /// Takes the page a client granted and remembers whose it is.
    ///
    /// Keyed on the badge the kernel put on the message, never on anything the
    /// client said about itself, so nobody can register a page in another
    /// reader's name.
    ///
    /// The order is the whole of it. Exactly one page, and the count comes from
    /// the kernel rather than from the word in the request; the number this
    /// attachment will carry is minted before anything is mapped, so the one
    /// irreversible step is last; the new window is mapped and owned before the
    /// old one is let go, so a registration that fails leaves the reader it had.
    private mutating func register(_ request: inout ReceivedMessage) {
        let badge = request.identity

        // No reply on this path: the request carried a capability, and a message
        // that carries one is a send. The caller asks `status` afterwards.
        guard badge != 0,
              request.message.tag.length == 2,
              request.message.words[0] == Self.readerPages,
              request.message.words[1] != 0,
              let granted = request.grantedCap
        else { return }

        guard reader.acceptsRegistration(
            identity: badge,
            currentIsLive: reader.current.map { identityAlive($0.identity) } ?? false
        ) else { return }

        let pages = shmPages(handle: granted)
        guard ShmAttachment.accepts(pages: pages, atMost: Self.readerPages) else { return }

        guard let epoch = reader.nextEpoch() else { return }

        let address = shmMap(handle: granted)
        guard UnsafeMutableRawPointer(bitPattern: UInt(address)) != nil else { return }

        let extent = UInt64(pages) * Self.pageSize

        guard let owned = request.takeGrant() else {
            _ = munmap(addr: address, size: extent)
            return
        }

        // `install` hands back whatever it displaced, and it is the only way in,
        // so a window cannot be replaced without this process being given the old
        // one to unmap.
        if let displaced = reader.install(ShmAttachment(
            identity: badge,
            epoch   : epoch,
            token   : request.message.words[1],
            address : address,
            extent  : extent,
            grant   : owned
        )) {
            surrender(displaced)
        }
    }


    /// Whether the caller is the registered reader.
    private mutating func status(_ request: inout ReceivedMessage) {
        let token = request.message.words[0]
        let known = request.message.tag.length == 1 && reader.held(by: request.identity, token: token)

        _ = reply(message: TerminalOperation.status.message(
            word0: known ? TerminalStatus.ok.rawValue : TerminalStatus.unregistered.rawValue,
            word1: known ? token : 0
        ))
    }


    private mutating func readLine(_ request: inout ReceivedMessage) {

        guard let held = reader.current,
              held.matches(identity: request.identity, token: request.message.words[2]),
              held.covers(0, UInt64(Terminal.lineLimit)),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))
        else {
            replyRead(status: .unregistered, sequence: 0, length: 0, token: 0)
            return
        }

        let sequence = request.message.words[0]
        let length = Int(request.message.words[1])
        if request.message.tag.length == 3, length == 0 {
            guard let event = input(sequence: sequence) else {
                replyRead(status: .refused, sequence: sequence, length: 0, token: request.message.words[2])
                return
            }
            let written = event.encode(
                into: page.assumingMemoryBound(to: UInt8.self),
                capacity: Int(held.extent)
            )
            guard written > 0 else {
                replyRead(status: .malformed, sequence: sequence, length: 0, token: request.message.words[2])
                return
            }
            replyRead(status: .ok, sequence: sequence, length: UInt32(written), token: request.message.words[2])
            return
        }
        guard request.message.tag.length == 3,
              length >= ShellProtocol.headerBytes,
              length <= Int(held.extent),
              let presentation = ShellFrame.decode(page.assumingMemoryBound(to: UInt8.self), length: length),
              presentation.envelope.schema == .presentation,
              presentation.envelope.flags.isEmpty,
              presentation.envelope.sequence == sequence,
              presentation.envelope.recordCount == 1,
              let prompt = presentation.text(at: 0),
              prompt.count <= Terminal.lineLimit
        else {
            replyRead(status: .malformed, sequence: sequence, length: 0, token: request.message.words[2])
            return
        }

        for index in 0..<prompt.count { putchar(ch: prompt.bytes[index]) }
        consoleFlush()

        let event: TerminalEvent
        if let edited = edit(into: page.assumingMemoryBound(to: UInt8.self)) {
            event = edited >= 0
                ? TerminalEvent.line(
                    sequence: sequence,
                    bytes: page.assumingMemoryBound(to: UInt8.self),
                    count: edited
                )
                : TerminalEvent.interrupted(sequence: sequence)
        } else {
            event = TerminalEvent.eof(sequence: sequence)
        }
        let eventLength = event.encode(
            into: page.assumingMemoryBound(to: UInt8.self),
            capacity: Int(held.extent)
        )
        guard eventLength > 0 else {
            replyRead(status: .refused, sequence: sequence, length: 0, token: request.message.words[2])
            return
        }

        replyRead(status: .ok, sequence: sequence, length: UInt32(eventLength), token: request.message.words[2])
    }

    private func replyRead(status: TerminalStatus, sequence: UInt32, length: UInt32, token: UInt32) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = sequence
        words[2] = length
        words[3] = token
        _ = reply(message: Message(
            tag: MessageTag(TerminalOperation.readLine, length: 4),
            words: words
        ))
    }

    private func present(_ request: inout ReceivedMessage) {
        guard let held = reader.current,
              held.matches(identity: request.identity, token: request.message.words[2]),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))
        else {
            replyPresented(status: .unregistered, sequence: 0, length: 0, token: 0)
            return
        }
        let sequence = request.message.words[0]
        let length = Int(request.message.words[1])
        if request.message.tag.length == 3,
           length >= TerminalRenderPatch.headerBytes,
           length <= Int(held.extent),
           let patch = TerminalRenderPatch.decode(page.assumingMemoryBound(to: UInt8.self), length: length),
           patch.sequence == sequence {
            #if REIX_TERMINAL_PROFILE
            mark(.presentationRequested, correlation: sequence, value: UInt32(clamping: min(length, Int(Self.maximumTraceValue))))
            #endif
            let emittedBytes = render(patch)
            consoleFlush()
            #if REIX_TERMINAL_PROFILE
            mark(.uartAccepted, correlation: sequence, value: emittedBytes)
            #endif
            replyPresented(status: .ok, sequence: sequence, length: UInt32(length), token: request.message.words[2])
            return
        }
        guard request.message.tag.length == 3,
              length >= ShellProtocol.headerBytes,
              length <= Int(held.extent),
              let frame = ShellFrame.decode(page.assumingMemoryBound(to: UInt8.self), length: length),
              frame.envelope.schema == .presentation,
              frame.envelope.flags.isEmpty,
              frame.envelope.sequence == sequence,
              frame.envelope.recordCount == 1,
              let text = frame.text(at: 0), text.count <= TerminalEvent.maximumPayload
        else {
            replyPresented(status: .malformed, sequence: sequence, length: 0, token: request.message.words[2])
            return
        }
        for index in 0..<text.count { putchar(ch: text.bytes[index]) }
        consoleFlush()
        replyPresented(status: .ok, sequence: sequence, length: UInt32(length), token: request.message.words[2])
    }

    private func render(_ patch: TerminalRenderPatch) -> UInt32 {
        var count: UInt32 = 0
        switch patch.kind {
            case .insert:
                for index in 0..<patch.count { emitted(patch.text[index], count: &count) }
            case .eraseBackward:
                for _ in 0..<patch.amount {
                    erase()
                    addEmitted(3, to: &count)
                }
            case .moveLeft:
                cursor(amount: patch.amount, direction: Self.cursorLeft, count: &count)
            case .moveRight:
                cursor(amount: patch.amount, direction: Self.cursorRight, count: &count)
            case .newline:
                emitted(Self.lineFeed, count: &count)
            case .replaceBuffer:
                emitted(Self.carriageReturn, count: &count)
                cursor(amount: patch.previousCursorRow, direction: Self.cursorUp, count: &count)
                var oldRow: UInt16 = 0
                while oldRow < patch.previousRows {
                    clearLine(count: &count)
                    oldRow += 1
                    if oldRow < patch.previousRows {
                        cursor(amount: 1, direction: Self.cursorDown, count: &count)
                        emitted(Self.carriageReturn, count: &count)
                    }
                }
                if patch.previousRows > 1 {
                    cursor(amount: patch.previousRows - 1, direction: Self.cursorUp, count: &count)
                    emitted(Self.carriageReturn, count: &count)
                }
                var finalRow: UInt16 = 0
                for index in 0..<patch.count {
                    let byte = patch.text[index]
                    emitted(byte, count: &count)
                    if byte == Self.lineFeed { emitted(Self.carriageReturn, count: &count); finalRow += 1 }
                }
                if finalRow > patch.cursorRow {
                    cursor(amount: finalRow - patch.cursorRow, direction: Self.cursorUp, count: &count)
                }
                emitted(Self.carriageReturn, count: &count)
                cursor(amount: patch.cursorColumn, direction: Self.cursorRight, count: &count)
            case .bell:
                emitted(Self.bell, count: &count)
        }
        return count
    }

    private func emitted(
        _ byte: UInt8,
        count : inout UInt32
    ) {
        putchar(ch: byte)
        if count < Self.maximumTraceValue { count += 1 }
    }

    private func addEmitted(
        _ amount: UInt32,
        to count: inout UInt32
    ) {
        count = min(Self.maximumTraceValue, count.addingReportingOverflow(amount).overflow ? UInt32.max : count + amount)
    }

    private func cursor(
        amount   : UInt16,
        direction: UInt8,
        count    : inout UInt32
    ) {
        guard amount > 0 else { return }
        emitted(Self.escape, count: &count)
        emitted(Self.openBracket, count: &count)
        let value = UInt64(amount)
        var divisor: UInt64 = 1
        while value / divisor >= 10 { divisor *= 10 }
        while divisor > 0 {
            emitted(UInt8((value / divisor) % 10) + 0x30, count: &count)
            divisor /= 10
        }
        emitted(direction, count: &count)
    }

    private func clearLine(count: inout UInt32) {
        emitted(Self.escape, count: &count)
        emitted(Self.openBracket, count: &count)
        emitted(UInt8(ascii: "2"), count: &count)
        emitted(UInt8(ascii: "K"), count: &count)
    }

    private mutating func input(sequence: UInt32) -> TerminalInputEvent? {
        guard let byte = nextByte() else { return nil }
        #if REIX_TERMINAL_PROFILE
        mark(.serialFirstByte, correlation: sequence, value: 1)
        #endif
        switch byte {
            case Self.interrupt: return decoded(TerminalInputEvent(kind: .cancel, sequence: sequence))
            case Self.eof: return decoded(TerminalInputEvent(kind: .eof, sequence: sequence))
            case Self.carriageReturn, Self.lineFeed: return decoded(TerminalInputEvent(kind: .enter, sequence: sequence))
            case Self.backspace, Self.delete: return decoded(TerminalInputEvent(kind: .backspace, sequence: sequence))
            case Self.escape:
                guard let bracket = nextByte(), bracket == Self.openBracket, let code = nextByte() else {
                    return decoded(TerminalInputEvent(kind: .ignored, sequence: sequence))
                }
                switch code {
                    case UInt8(ascii: "A"): return decoded(TerminalInputEvent(kind: .up, sequence: sequence))
                    case UInt8(ascii: "B"): return decoded(TerminalInputEvent(kind: .down, sequence: sequence))
                    case UInt8(ascii: "C"): return decoded(TerminalInputEvent(kind: .right, sequence: sequence))
                    case UInt8(ascii: "D"): return decoded(TerminalInputEvent(kind: .left, sequence: sequence))
                    case UInt8(ascii: "H"): return decoded(TerminalInputEvent(kind: .home, sequence: sequence))
                    case UInt8(ascii: "F"): return decoded(TerminalInputEvent(kind: .end, sequence: sequence))
                    case UInt8(ascii: "3"):
                        guard nextByte() == Self.tilde else { return decoded(TerminalInputEvent(kind: .ignored, sequence: sequence)) }
                        return decoded(TerminalInputEvent(kind: .delete, sequence: sequence))
                    default: return decoded(TerminalInputEvent(kind: .ignored, sequence: sequence))
                }
            case let printable where printable >= 0x20:
                var encoded = InlineArray<4, UInt8>(repeating: 0)
                encoded[0] = printable
                let expected: Int
                switch printable {
                    case 0x20...0x7F: expected = 1
                    case 0xC2...0xDF: expected = 2
                    case 0xE0...0xEF: expected = 3
                    case 0xF0...0xF4: expected = 4
                    default: return decoded(TerminalInputEvent(kind: .ignored, sequence: sequence))
                }
                if expected > 1 {
                    for index in 1..<expected {
                        guard let continuation = nextByte() else { return nil }
                        encoded[index] = continuation
                    }
                }
                return encoded.span.withUnsafeBufferPointer {
                    let event = TerminalInputEvent(sequence: sequence, bytes: $0.baseAddress!, count: expected)
                    return decoded(event.count == expected ? event : TerminalInputEvent(kind: .ignored, sequence: sequence))
                }
            default: return decoded(TerminalInputEvent(kind: .ignored, sequence: sequence))
        }
    }

    private func decoded(_ event: TerminalInputEvent) -> TerminalInputEvent {
        #if REIX_TERMINAL_PROFILE
        mark(.inputDecoded, correlation: event.sequence, value: UInt32(event.count))
        #endif
        return event
    }

    private mutating func nextByte() -> UInt8? {
        while true {
            let read = pl011TryReadByte(uartBase)
            if read != Self.fifoEmpty { return UInt8(truncatingIfNeeded: read) }
            pl011ClearReceive(uartBase)
            if delivered != 0 { _ = irqAck(handle: interrupt, bits: delivered); delivered = 0 }
            let fired = irqWait(handle: interrupt)
            guard fired != UInt64.max else { return nil }
            delivered = fired
        }
    }

    private func replyPresented(status: TerminalStatus, sequence: UInt32, length: UInt32, token: UInt32) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = sequence
        words[2] = length
        words[3] = token
        _ = reply(message: Message(
            tag: MessageTag(TerminalOperation.present, length: 4),
            words: words
        ))
    }


    /// The editor: keystrokes in, one line out.
    private mutating func edit(into line: UnsafeMutablePointer<UInt8>) -> Int? {

        var count = 0

        while true {
            // Drain first and wait second, always: keys pressed before this
            // call, or between the last drain and the mask, are already in the
            // FIFO and no interrupt is coming to announce them.
            while true {
                let read = pl011TryReadByte(uartBase)
                guard read != Self.fifoEmpty else { break }

                switch UInt8(truncatingIfNeeded: read) {
                    case Self.carriageReturn, Self.lineFeed:
                        putchar(ch: Self.lineFeed)
                        consoleFlush()

                        return count

                    case Self.interrupt:
                        putchar(ch: Self.caret)
                        putchar(ch: Self.interruptLetter)
                        putchar(ch: Self.lineFeed)
                        consoleFlush()
                        return -1

                    case Self.delete, Self.backspace:
                        guard count > 0 else { break }
                        count -= 1
                        erase()

                    case let byte where byte >= 0x20 && byte < Self.delete:
                        guard count < Terminal.lineLimit else { break }
                        line[count] = byte
                        count += 1

                        putchar(ch: byte)
                        consoleFlush()

                    default:
                        break // Control characters this terminal has no meaning for yet.
                }
            }

            // Acknowledge at the device before unmasking at the controller, or
            // the same condition raises the line again the moment it is armed.
            pl011ClearReceive(uartBase)

            if delivered != 0 {
                _ = irqAck(handle: interrupt, bits: delivered)
                delivered = 0
            }

            let fired = irqWait(handle: interrupt)
            guard fired != UInt64.max else { return nil }

            delivered = fired
        }
    }


    /// Backspace, space, backspace: the character is painted out, which is what
    /// a terminal that cannot address the cursor has to do.
    private func erase() {
        putchar(ch: Self.backspace)
        putchar(ch: 0x20)
        putchar(ch: Self.backspace)

        consoleFlush()
    }


    private static let fifoEmpty     : UInt32 = 0x100
    private static let eof           : UInt8  = 0x04
    private static let interrupt     : UInt8  = 0x03
    private static let caret         : UInt8  = 0x5E
    private static let interruptLetter: UInt8 = 0x43
    private static let carriageReturn: UInt8  = 0x0D
    private static let lineFeed      : UInt8  = 0x0A
    private static let backspace     : UInt8  = 0x08
    private static let delete        : UInt8  = 0x7F
    private static let escape        : UInt8  = 0x1B
    private static let openBracket   : UInt8  = 0x5B
    private static let tilde         : UInt8  = 0x7E
    private static let bell          : UInt8  = 0x07
    private static let cursorLeft    : UInt8  = 0x44
    private static let cursorRight   : UInt8  = 0x43
    private static let cursorUp      : UInt8  = 0x41
    private static let cursorDown    : UInt8  = 0x42
}
