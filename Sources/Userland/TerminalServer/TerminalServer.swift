//
//  TerminalServer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// The UART/VT adapter for the semantic terminal transport.
public struct TerminalServer: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint: UInt32
    private let uartBase: UnsafeMutableRawPointer
    private let interrupt: UInt32
    #if REIX_TERMINAL_PROFILE
    private let profileMarker: UInt32
    #endif
    private var reader = ShmAttachment.Slot()
    private var delivered: UInt64 = 0

    private static let pageSize: UInt64 = 4096
    private static let readerPages: UInt32 = UInt32(ReixTerminalTransport.pages)
    private static let maximumTraceValue: UInt32 = 0x00FF_FFFF

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

    public init(environment: Environment, endpoint: UInt32) {
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
        guard let mapped = UnsafeMutableRawPointer(bitPattern: UInt(mapDevice(handle: device))) else {
            print("[ SERVE ] Terminal Server cannot map the serial window")
            exit(code: 1)
        }
        self.uartBase = mapped
        self.interrupt = interrupt
        pl011EnableReceive(mapped)
        print("[ SERVE ] Terminal Server running")
    }

    public mutating func handle(_ operation: TerminalOperation, request: inout ReceivedMessage) {
        sweepDeadReader()
        switch operation {
            case .register: register(&request)
            case .status: status(&request)
            case .awaitInput: awaitInput(&request)
            case .present: present(&request)
        }
    }

    private mutating func sweepDeadReader() {
        guard let held = reader.current, !identityAlive(held.identity) else { return }
        _ = reader.take()
        surrender(held)
    }

    private func surrender(_ attachment: ShmAttachment) {
        _ = munmap(addr: attachment.address, size: attachment.extent)
        _ = capDrop(attachment.grant)
    }

    private mutating func register(_ request: inout ReceivedMessage) {
        let badge = request.identity
        let token = request.message.words[1]
        guard badge != 0,
              request.message.tag.length == 2,
              request.message.words[0] == Self.readerPages,
              token != 0,
              let granted = request.grantedCap,
              reader.acceptsRegistration(identity: badge, currentIsLive: reader.current.map { identityAlive($0.identity) } ?? false),
              shmPages(handle: granted) == Self.readerPages,
              let epoch = reader.nextEpoch()
        else { return }
        let address = shmMap(handle: granted)
        guard let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self) else { return }
        let extent = UInt64(Self.readerPages) * Self.pageSize
        guard ReixTerminalRing.accept(page: page, role: .input, token: token, epoch: epoch),
              ReixTerminalRing.accept(page: page.advanced(by: ReixTerminalTransport.pageBytes), role: .surface, token: token, epoch: epoch),
              let owned = request.takeGrant()
        else { _ = munmap(addr: address, size: extent); return }
        if let displaced = reader.install(ShmAttachment(identity: badge, epoch: epoch, token: token, address: address, extent: extent, grant: owned)) {
            surrender(displaced)
        }
    }

    private func status(_ request: inout ReceivedMessage) {
        let token = request.message.words[0]
        let held = request.message.tag.length == 1 ? reader.current : nil
        let known: Bool
        if let held {
            known = held.matches(identity: request.identity, token: token) && coherent(held)
        } else {
            known = false
        }
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = known ? TerminalStatus.ok.rawValue : TerminalStatus.unregistered.rawValue
        words[1] = known ? token : 0
        if let held, known {
            words[2] = UInt32(truncatingIfNeeded: held.epoch)
            words[3] = UInt32(truncatingIfNeeded: held.epoch >> 32)
        }
        _ = reply(message: Message(tag: MessageTag(TerminalOperation.status, length: 4), words: words))
    }

    private mutating func awaitInput(_ request: inout ReceivedMessage) {
        guard let held = validated(request),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))?.assumingMemoryBound(to: UInt8.self),
              let event = input(sequence: request.message.words[0]),
              let ring = ReixTerminalRing(page: page, role: .input, token: held.token, epoch: held.epoch),
              ring.push(event)
        else { replyOperation(.awaitInput, status: .refused, sequence: request.message.words[0], token: 0, epoch: 0); return }
        replyOperation(.awaitInput, status: .ok, sequence: event.sequence, token: held.token, epoch: held.epoch)
    }

    private mutating func present(_ request: inout ReceivedMessage) {
        guard let held = validated(request),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixTerminalRing(page: page.advanced(by: ReixTerminalTransport.pageBytes), role: .surface, token: held.token, epoch: held.epoch),
              let command = ring.popSurface(sequence: request.message.words[0])
        else { replyOperation(.present, status: .refused, sequence: request.message.words[0], token: 0, epoch: 0); return }
        #if REIX_TERMINAL_PROFILE
        let tracedPresentation = ReixTerminalTransport.isCorrelatedSequence(command.sequence)
        if tracedPresentation {
            mark(.presentationRequested, correlation: command.sequence, value: UInt32(min(ReixTextSurfaceProtocol.recordBytes, Int(Self.maximumTraceValue))))
        }
        #endif
        let emittedBytes = render(command)
        consoleFlush()
        #if REIX_TERMINAL_PROFILE
        if tracedPresentation { mark(.uartAccepted, correlation: command.sequence, value: emittedBytes) }
        #endif
        replyOperation(.present, status: .ok, sequence: command.sequence, token: held.token, epoch: held.epoch)
    }

    private func validated(_ request: ReceivedMessage) -> ShmAttachment? {
        guard request.message.tag.length == 4,
              let held = reader.current,
              held.matches(identity: request.identity, token: request.message.words[1]),
              held.epoch == UInt64(request.message.words[2]) | UInt64(request.message.words[3]) << 32,
              held.covers(0, UInt64(ReixTerminalTransport.regionBytes)),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address)),
              coherent(held)
        else { return nil }
        _ = page
        return held
    }

    /// Replies may echo only the low epoch word, but status and every doorbell
    /// validate both accepted headers against the full attachment epoch first.
    private func coherent(_ held: ShmAttachment) -> Bool {
        guard let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))?.assumingMemoryBound(to: UInt8.self) else { return false }
        return ReixTerminalRing(page: page, role: .input, token: held.token, epoch: held.epoch) != nil
            && ReixTerminalRing(page: page.advanced(by: ReixTerminalTransport.pageBytes), role: .surface, token: held.token, epoch: held.epoch) != nil
    }

    private func replyOperation(_ operation: TerminalOperation, status: TerminalStatus, sequence: UInt32, token: UInt32, epoch: UInt64) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = sequence
        words[2] = token
        words[3] = UInt32(truncatingIfNeeded: epoch)
        _ = reply(message: Message(tag: MessageTag(operation, length: 4), words: words))
    }

    private func render(_ command: ReixTextSurfaceCommand) -> UInt32 {
        var count: UInt32 = 0
        switch command.kind {
            case .insert:
                for index in 0..<command.count { emitted(command.text[index], count: &count) }
            case .eraseBackward:
                for _ in 0..<command.amount { erase(); addEmitted(3, to: &count) }
            case .moveLeft: cursor(amount: command.amount, direction: Self.cursorLeft, count: &count)
            case .moveRight: cursor(amount: command.amount, direction: Self.cursorRight, count: &count)
            case .newline: emitted(Self.lineFeed, count: &count)
            case .replaceBuffer:
                emitted(Self.carriageReturn, count: &count)
                cursor(amount: command.previousCursorRow, direction: Self.cursorUp, count: &count)
                var oldRow: UInt16 = 0
                while oldRow < command.previousRows {
                    clearLine(count: &count)
                    oldRow += 1
                    if oldRow < command.previousRows { cursor(amount: 1, direction: Self.cursorDown, count: &count); emitted(Self.carriageReturn, count: &count) }
                }
                if command.previousRows > 1 { cursor(amount: command.previousRows - 1, direction: Self.cursorUp, count: &count); emitted(Self.carriageReturn, count: &count) }
                var finalRow: UInt16 = 0
                for index in 0..<command.count {
                    let byte = command.text[index]
                    emitted(byte, count: &count)
                    if byte == Self.lineFeed { emitted(Self.carriageReturn, count: &count); finalRow += 1 }
                }
                if finalRow > command.cursorRow { cursor(amount: finalRow - command.cursorRow, direction: Self.cursorUp, count: &count) }
                emitted(Self.carriageReturn, count: &count)
                cursor(amount: command.cursorColumn, direction: Self.cursorRight, count: &count)
            case .bell: emitted(Self.bell, count: &count)
        }
        return count
    }

    private func emitted(_ byte: UInt8, count: inout UInt32) { putchar(ch: byte); if count < Self.maximumTraceValue { count += 1 } }
    private func addEmitted(_ amount: UInt32, to count: inout UInt32) { let sum = count.addingReportingOverflow(amount); count = sum.overflow ? Self.maximumTraceValue : min(Self.maximumTraceValue, sum.partialValue) }
    private func cursor(amount: UInt16, direction: UInt8, count: inout UInt32) {
        guard amount > 0 else { return }
        emitted(Self.escape, count: &count); emitted(Self.openBracket, count: &count)
        var divisor: UInt64 = 1
        while UInt64(amount) / divisor >= 10 { divisor *= 10 }
        while divisor > 0 { emitted(UInt8((UInt64(amount) / divisor) % 10) + 0x30, count: &count); divisor /= 10 }
        emitted(direction, count: &count)
    }
    private func clearLine(count: inout UInt32) { emitted(Self.escape, count: &count); emitted(Self.openBracket, count: &count); emitted(UInt8(ascii: "2"), count: &count); emitted(UInt8(ascii: "K"), count: &count) }
    private func erase() { putchar(ch: Self.backspace); putchar(ch: 0x20); putchar(ch: Self.backspace); consoleFlush() }

    private mutating func input(sequence: UInt32) -> ReixInputRecord? {
        guard sequence != 0, let byte = nextByte() else { return nil }
        #if REIX_TERMINAL_PROFILE
        mark(.serialFirstByte, correlation: sequence, value: 1)
        #endif
        let event: ReixInputRecord?
        switch byte {
            case Self.interrupt: event = ReixInputRecord(kind: .cancel, sequence: sequence)
            case Self.eof: event = ReixInputRecord(kind: .eof, sequence: sequence)
            case Self.carriageReturn, Self.lineFeed: event = ReixInputRecord(kind: .enter, sequence: sequence)
            case Self.backspace, Self.delete: event = ReixInputRecord(kind: .backspace, sequence: sequence)
            case Self.escape:
                guard let bracket = nextByte(), bracket == Self.openBracket, let code = nextByte() else { event = ReixInputRecord(kind: .ignored, sequence: sequence); break }
                switch code {
                    case UInt8(ascii: "A"): event = ReixInputRecord(kind: .up, sequence: sequence)
                    case UInt8(ascii: "B"): event = ReixInputRecord(kind: .down, sequence: sequence)
                    case UInt8(ascii: "C"): event = ReixInputRecord(kind: .right, sequence: sequence)
                    case UInt8(ascii: "D"): event = ReixInputRecord(kind: .left, sequence: sequence)
                    case UInt8(ascii: "H"): event = ReixInputRecord(kind: .home, sequence: sequence)
                    case UInt8(ascii: "F"): event = ReixInputRecord(kind: .end, sequence: sequence)
                    case UInt8(ascii: "3"): event = nextByte() == Self.tilde ? ReixInputRecord(kind: .delete, sequence: sequence) : ReixInputRecord(kind: .ignored, sequence: sequence)
                    default: event = ReixInputRecord(kind: .ignored, sequence: sequence)
                }
            case let printable where printable >= 0x20:
                var encoded = InlineArray<4, UInt8>(repeating: 0)
                encoded[0] = printable
                let expected: Int
                switch printable { case 0x20...0x7F: expected = 1; case 0xC2...0xDF: expected = 2; case 0xE0...0xEF: expected = 3; case 0xF0...0xF4: expected = 4; default: expected = 0 }
                guard expected > 0 else { event = ReixInputRecord(kind: .ignored, sequence: sequence); break }
                if expected > 1 { for index in 1..<expected { guard let continuation = nextByte() else { return nil }; encoded[index] = continuation } }
                event = encoded.span.withUnsafeBufferPointer { ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0.baseAddress!, count: expected) }
            default: event = ReixInputRecord(kind: .ignored, sequence: sequence)
        }
        guard let event else { return nil }
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

    private static let fifoEmpty: UInt32 = 0x100
    private static let eof: UInt8 = 0x04
    private static let interrupt: UInt8 = 0x03
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let backspace: UInt8 = 0x08
    private static let delete: UInt8 = 0x7F
    private static let escape: UInt8 = 0x1B
    private static let openBracket: UInt8 = 0x5B
    private static let tilde: UInt8 = 0x7E
    private static let bell: UInt8 = 0x07
    private static let cursorLeft: UInt8 = 0x44
    private static let cursorRight: UInt8 = 0x43
    private static let cursorUp: UInt8 = 0x41
    private static let cursorDown: UInt8 = 0x42
}
