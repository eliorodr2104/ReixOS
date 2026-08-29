//
//  VTAdapter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/08/2026.
//

import Reix
import ReixABI

/// The adapter keeps presentation labels wire-compatible with TextSurface.
public enum VTAdapterOperation: UInt32, IPCLabel {
    case register = 0
    case status = 1
    case present = 2
    case produce = 5
}

/// The serial-to-semantic adapter and TextSurface presentation endpoint.
public struct VTAdapter: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint: UInt32
    #if REIX_TERMINAL_PROFILE
    private let profileMarker: UInt32
    #endif
    private var reader: SerialReaderSession
    private var source: SourceSession
    private var decoder = VTDecoder()
    private var pendingChunk: ReixSerialChunk?
    private var pendingOffset = 0
    private var surface = ShmAttachment.Slot()

    private static let pageSize: UInt64 = 4096
    private static let surfacePages = UInt32(ReixTextSurfaceTransport.pages)
    private static let maximumTraceValue: UInt32 = 0x00FF_FFFF

    public var serviceEndpoint: UInt32 { endpoint }

    #if REIX_TERMINAL_PROFILE
    @inline(__always)
    private func mark(_ point: InteractionTracePoint, correlation: UInt32, value: UInt32) {
        guard let mark = InteractionTraceMark(point: point, correlation: correlation, value: value) else {
            return
        }
        profileInteractionMark(mark, authority: profileMarker)
    }
    #endif

    public init(environment: Environment, endpoint: UInt32) {
        self.endpoint = endpoint
        guard let console = environment.console,
              let serialReader = environment.serialReader,
              let inputSource = environment.inputSource,
              let reader = SerialReaderSession(endpoint: serialReader),
              let source = SourceSession(endpoint: inputSource, callback: endpoint)
        else {
            print("[ SERVE ] VT Adapter has no terminal capabilities")
            exit(code: 1)
        }
        #if REIX_TERMINAL_PROFILE
        guard let profileMarker = environment.profileMarker else {
            print("[ SERVE ] VT Adapter has no profile marker")
            exit(code: 1)
        }
        self.profileMarker = profileMarker
        #endif
        Console.attach(console: console)
        self.reader = reader
        self.source = source
        guard emitBracketedPasteMode() else {
            print("[ SERVE ] VT Adapter could not enable bracketed paste")
            exit(code: 1)
        }
        print("[ SERVE ] VT Adapter running")
    }

    public mutating func handle(_ operation: VTAdapterOperation, request: inout ReceivedMessage) {
        sweepDeadSurface()
        switch operation {
            case .register:
                register(&request)
            case .status:
                status(&request)
            case .present:
                present(&request)
            case .produce:
                sourcePull(&request)
        }
    }

    private mutating func sourcePull(_ request: inout ReceivedMessage) {
        guard request.message.tag.length == 1,
              request.message.words[0] != 0
        else {
            replySource(.refused)
            return
        }
        let correlation = request.message.words[0]
        if let event = decoder.pop() {
            replySource(publish(event, correlation: correlation))
            return
        }
        let status = decodeOneChunk(correlation: correlation)
        guard status == .ok else {
            replySource(status)
            return
        }
        guard let event = decoder.pop() else {
            replySource(.empty)
            return
        }
        replySource(publish(event, correlation: correlation))
    }

    private mutating func decodeOneChunk(correlation: UInt32) -> ReixInputSourceStatus {
        if let pending = pendingChunk {
            let consumed = pending.payload.span.withUnsafeBufferPointer {
                decoder.consume(
                    $0.baseAddress! + pendingOffset,
                    count: pending.count - pendingOffset
                )
            }
            pendingOffset += consumed
            if pendingOffset == pending.count {
                pendingChunk = nil
                pendingOffset = 0
            }
            return consumed == 0 && decoder.isEmpty ? .empty : .ok
        }
        switch reader.read() {
            case .chunk(let chunk):
                #if REIX_TERMINAL_PROFILE
                mark(
                    .serialDelivered,
                    correlation: correlation,
                    value: UInt32(chunk.count)
                )
                #endif
                pendingChunk = chunk
                pendingOffset = 0
                return decodeOneChunk(correlation: correlation)
            case .status(.empty):
                return finishIdle(.empty)
            case .status(.timedOut):
                return finishIdle(.timedOut)
            case .status(.stale):
                return .stale
            case .status:
                return .refused
        }
    }

    private mutating func finishIdle(_ status: ReixInputSourceStatus) -> ReixInputSourceStatus {
        guard decoder.finishIdle() else {
            return .refused
        }
        return decoder.isEmpty ? status : .ok
    }

    private func publish(
        _ event: ReixInputRecord,
        correlation: UInt32
    ) -> ReixInputSourceStatus {
        #if REIX_TERMINAL_PROFILE
        mark(
            .inputDecoded,
            correlation: correlation,
            value: UInt32(event.kind.rawValue)
        )
        #endif
        return source.publish(event) == .ok ? .ok : .stale
    }

    private func replySource(_ status: ReixInputSourceStatus) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        _ = reply(message: Message(tag: MessageTag(ReixInputSourceOperation.produce, length: 1), words: words))
    }

    private mutating func sweepDeadSurface() {
        guard let held = surface.current, !identityAlive(held.identity) else {
            return
        }
        _ = surface.take()
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
              request.message.words[0] == Self.surfacePages,
              token != 0,
              let granted = request.grantedCap,
              surface.acceptsRegistration(
                  identity: badge,
                  currentIsLive: surface.current.map {
                      identityAlive($0.identity)
                  } ?? false
              ),
              shmPages(handle: granted) == Self.surfacePages,
              let epoch = surface.nextEpoch()
        else {
            return
        }
        let address = shmMap(handle: granted)
        guard let page = UnsafeMutableRawPointer(bitPattern: UInt(address))?.assumingMemoryBound(to: UInt8.self) else {
            return
        }
        let extent = UInt64(Self.surfacePages) * Self.pageSize
        guard ReixTextSurfaceRing.accept(page: page, token: token, epoch: epoch),
              let owned = request.takeGrant()
        else {
            _ = munmap(addr: address, size: extent)
            return
        }
        let attachment = ShmAttachment(
            identity: badge,
            epoch: epoch,
            token: token,
            address: address,
            extent: extent,
            grant: owned
        )
        if let displaced = surface.install(attachment) {
            surrender(displaced)
        }
    }

    private func status(_ request: inout ReceivedMessage) {
        let token = request.message.words[0]
        let held = request.message.tag.length == 1 ? surface.current : nil
        let known = held.map { $0.matches(identity: request.identity, token: token) && coherent($0) } ?? false
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = known ? ReixTextSurfaceStatus.ok.rawValue : ReixTextSurfaceStatus.unregistered.rawValue
        words[1] = known ? token : 0
        if let held, known {
            words[2] = UInt32(truncatingIfNeeded: held.epoch)
            words[3] = UInt32(truncatingIfNeeded: held.epoch >> 32)
        }
        _ = reply(message: Message(tag: MessageTag(VTAdapterOperation.status, length: 4), words: words))
    }

    private mutating func present(_ request: inout ReceivedMessage) {
        guard let held = validated(request),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixTextSurfaceRing(page: page, token: held.token, epoch: held.epoch),
              let command = ring.pop(sequence: request.message.words[0])
        else {
            replyOperation(.present, status: .refused, sequence: request.message.words[0], token: 0, epoch: 0)
            return
        }
        #if REIX_TERMINAL_PROFILE
        if ReixInteractionSequence.isCorrelated(command.sequence) {
            mark(
                .presentationRequested,
                correlation: command.sequence,
                value: UInt32(ReixTextSurfaceProtocol.recordBytes)
            )
        }
        #endif
        let emittedBytes = render(command)
        guard consoleFlush() else {
            replyOperation(
                .present,
                status: .refused,
                sequence: command.sequence,
                token: held.token,
                epoch: held.epoch
            )
            return
        }
        #if REIX_TERMINAL_PROFILE
        if ReixInteractionSequence.isCorrelated(command.sequence) {
            mark(.consoleAcknowledged, correlation: command.sequence, value: emittedBytes)
        }
        #endif
        replyOperation(.present, status: .ok, sequence: command.sequence, token: held.token, epoch: held.epoch)
    }

    private func validated(_ request: ReceivedMessage) -> ShmAttachment? {
        guard request.message.tag.length == 4,
              let held = surface.current,
              held.matches(identity: request.identity, token: request.message.words[1]),
              held.epoch == UInt64(request.message.words[2]) | UInt64(request.message.words[3]) << 32,
              held.covers(0, UInt64(ReixTextSurfaceTransport.regionBytes)),
              coherent(held)
        else {
            return nil
        }
        return held
    }

    private func coherent(_ held: ShmAttachment) -> Bool {
        guard let raw = UnsafeMutableRawPointer(
            bitPattern: UInt(held.address)
        ) else {
            return false
        }
        let page = raw.assumingMemoryBound(to: UInt8.self)
        return ReixTextSurfaceRing(page: page, token: held.token, epoch: held.epoch) != nil
    }

    private func replyOperation(
        _ operation: VTAdapterOperation,
        status: ReixTextSurfaceStatus,
        sequence: UInt32,
        token: UInt32,
        epoch: UInt64
    ) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = sequence
        words[2] = token
        words[3] = UInt32(truncatingIfNeeded: epoch)
        _ = reply(message: Message(tag: MessageTag(operation, length: 4), words: words))
    }

    private func emitBracketedPasteMode() -> Bool {
        emit(Self.escape)
        emit(Self.openBracket)
        emit(UInt8(ascii: "?"))
        emit(UInt8(ascii: "2"))
        emit(UInt8(ascii: "0"))
        emit(UInt8(ascii: "0"))
        emit(UInt8(ascii: "4"))
        emit(UInt8(ascii: "h"))
        return consoleFlush()
    }

    private func render(_ command: ReixTextSurfaceCommand) -> UInt32 {
        var count: UInt32 = 0
        switch command.kind {
            case .insert:
                for index in 0..<command.count {
                    emitted(command.text[index], count: &count)
                }
            case .eraseBackward:
                for _ in 0..<command.amount {
                    emitted(Self.backspace, count: &count)
                    emitted(0x20, count: &count)
                    emitted(Self.backspace, count: &count)
                }
            case .moveLeft:
                cursor(amount: command.amount, direction: Self.cursorLeft, count: &count)
            case .moveRight:
                cursor(amount: command.amount, direction: Self.cursorRight, count: &count)
            case .newline:
                emitted(Self.lineFeed, count: &count)
            case .replaceBuffer:
                renderReplacement(command, count: &count)
            case .bell:
                emitted(Self.bell, count: &count)
        }
        return count
    }

    private func renderReplacement(_ command: ReixTextSurfaceCommand, count: inout UInt32) {
        emitted(Self.carriageReturn, count: &count)
        cursor(amount: command.previousCursorRow, direction: Self.cursorUp, count: &count)
        var oldRow: UInt16 = 0
        while oldRow < command.previousRows {
            clearLine(count: &count)
            oldRow += 1
            if oldRow < command.previousRows {
                cursor(amount: 1, direction: Self.cursorDown, count: &count)
                emitted(Self.carriageReturn, count: &count)
            }
        }
        if command.previousRows > 1 {
            cursor(amount: command.previousRows - 1, direction: Self.cursorUp, count: &count)
            emitted(Self.carriageReturn, count: &count)
        }
        var finalRow: UInt16 = 0
        for index in 0..<command.count {
            let byte = command.text[index]
            emitted(byte, count: &count)
            if byte == Self.lineFeed {
                emitted(Self.carriageReturn, count: &count)
                finalRow += 1
            }
        }
        if finalRow > command.cursorRow {
            cursor(amount: finalRow - command.cursorRow, direction: Self.cursorUp, count: &count)
        }
        emitted(Self.carriageReturn, count: &count)
        cursor(amount: command.cursorColumn, direction: Self.cursorRight, count: &count)
    }

    private func emitted(_ byte: UInt8, count: inout UInt32) {
        emit(byte)
        if count < Self.maximumTraceValue {
            count += 1
        }
    }

    private func emit(_ byte: UInt8) {
        putchar(ch: byte)
    }

    private func cursor(amount: UInt16, direction: UInt8, count: inout UInt32) {
        guard amount > 0 else {
            return
        }
        emitted(Self.escape, count: &count)
        emitted(Self.openBracket, count: &count)
        var divisor: UInt64 = 1
        while UInt64(amount) / divisor >= 10 {
            divisor *= 10
        }
        while divisor > 0 {
            emitted(UInt8((UInt64(amount) / divisor) % 10) + 0x30, count: &count)
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

    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let backspace: UInt8 = 0x08
    private static let escape: UInt8 = 0x1B
    private static let openBracket: UInt8 = 0x5B
    private static let bell: UInt8 = 0x07
    private static let cursorLeft: UInt8 = 0x44
    private static let cursorRight: UInt8 = 0x43
    private static let cursorUp: UInt8 = 0x41
    private static let cursorDown: UInt8 = 0x42
}
