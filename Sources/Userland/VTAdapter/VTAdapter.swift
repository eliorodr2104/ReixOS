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
    case drainPartial = 3
    case produce = 5
}

/// The serial-to-semantic adapter and TextSurface presentation endpoint.
public struct VTAdapter: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private let endpoint: UInt32
    #if REIX_TERMINAL_PROFILE
    private let profileMarker: UInt32
    #endif
    private var reader               : SerialReaderSession
    private var source               : SourceSession
    private var decoder              = VTDecoder()
    private var pendingChunk         : ReixSerialChunk?
    private var pendingOffset        = 0
    private var surface              = ShmAttachment.Slot()
    private var screen               = TextSurfaceScreenModel()
    private var compatibilityClients = InlineArray<32, UInt32?>(repeating: nil)
    private var compatibilityRings   = InlineArray<32, Ring?>(repeating: nil)
    private var compatibilityGrants  = InlineArray<32, UInt32?>(repeating: nil)
    private var compatibilityIndex   = 0

    private static let pageSize           : UInt64 = 4096
    private static let surfacePages       = UInt32(ReixTextSurfaceTransport.pages)
    private static let compatibilityPages : UInt32 = 1
    private static let maximumTraceValue  : UInt32 = 0x00FF_FFFF

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
        guard emitTerminalModes() else {
            print("[ SERVE ] VT Adapter could not enable terminal modes")
            exit(code: 1)
        }
        print("[ SERVE ] VT Adapter running")
    }

    public mutating func handle(_ operation: VTAdapterOperation, request: inout ReceivedMessage) {
        sweepDeadSurface()
        sweepDeadCompatibilityClients()
        switch operation {
            case .register:
                if request.message.tag.length == 1 {
                    registerCompatibility(&request)
                } else {
                    registerSurface(&request)
                }
            case .status:
                if request.message.tag.length == 1,
                   request.message.words[0] == 0,
                   compatibilitySlot(for: request.identity) != nil {
                    kickCompatibility()
                } else {
                    surfaceStatus(&request)
                }
            case .present:
                if request.message.tag.length == 1 {
                    flushCompatibility(&request)
                } else {
                    presentSurface(&request)
                }
            case .drainPartial:
                drainPartialCompatibility(&request)
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
            let consumed = pending.payload.withUnsafeBufferPointer {
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

    /// Temporary ingress for existing `ConsoleClient` producers. It converts
    /// their bounded UTF-8 rings to authenticated semantic records before any
    /// byte reaches the VT backend. New producers should use TextSurface records.
    private mutating func registerCompatibility(_ request: inout ReceivedMessage) {
        let identity = request.identity
        guard identity != 0,
              request.message.words[0] == Self.compatibilityPages,
              let granted = request.grantedCap,
              shmPages(handle: granted) == Self.compatibilityPages
        else { return }
        if let stale = compatibilitySlot(for: identity) {
            releaseCompatibility(slot: stale)
        }
        guard let slot = freeCompatibilitySlot() else { return }
        let address = shmMap(handle: granted, writable: true)
        guard let base = UnsafeMutableRawPointer(bitPattern: UInt(address)),
              let owned = request.takeGrant()
        else { return }
        compatibilityClients[slot] = identity
        compatibilityRings[slot] = Ring(base: base, regionSize: Int(Self.pageSize))
        compatibilityGrants[slot] = owned
    }

    private mutating func kickCompatibility() {
        for offset in 0..<compatibilityClients.count {
            let slot = (compatibilityIndex + offset) % compatibilityClients.count
            guard let source = compatibilityClients[slot],
                  let ring = compatibilityRings[slot]
            else { continue }
            _ = drainCompatibility(ring, source: source, includingPartialLine: false)
        }
        compatibilityIndex = (compatibilityIndex + 1) % compatibilityClients.count
    }

    private mutating func drainPartialCompatibility(_ request: inout ReceivedMessage) {
        guard let slot = compatibilitySlot(for: request.identity),
              let ring = compatibilityRings[slot]
        else { return }
        _ = drainCompatibility(ring, source: request.identity, includingPartialLine: true)
    }

    private mutating func flushCompatibility(_ request: inout ReceivedMessage) {
        var status = ConsoleStatus.unregistered
        if let slot = compatibilitySlot(for: request.identity),
           let ring = compatibilityRings[slot] {
            let drained = drainCompatibility(
                ring,
                source: request.identity,
                includingPartialLine: false
            )
            status = drained && consoleFlush() ? .registered : .failed
        }
        _ = reply(message: ConsoleOperation.flush.message(word0: status.rawValue))
    }

    private mutating func drainCompatibility(
        _ ring              : Ring,
        source              : UInt32,
        includingPartialLine: Bool
    ) -> Bool {
        var accepted = true
        while accepted && ring.consumeLineChecked({ first, firstCount, second, secondCount in
            accepted = presentCompatibility(
                source: source,
                first: first,
                firstCount: firstCount,
                second: second,
                secondCount: secondCount
            )
            return accepted
        }) { }
        if includingPartialLine && accepted && !ring.isEmpty {
            let consumed = ring.consumeAllChecked { first, firstCount, second, secondCount in
                accepted = presentCompatibility(
                    source: source,
                    first: first,
                    firstCount: firstCount,
                    second: second,
                    secondCount: secondCount
                )
                return accepted
            }
            if consumed == 0 && !ring.isEmpty { accepted = false }
        }
        return accepted
    }

    private mutating func presentCompatibility(
        source     : UInt32,
        first      : UnsafeRawPointer,
        firstCount : Int,
        second     : UnsafeRawPointer?,
        secondCount: Int
    ) -> Bool {
        guard let record = ReixTextOutputRecord(
            source: source,
            severity: .info,
            kind: .application,
            payloadKind: .utf8Text,
            first: first.assumingMemoryBound(to: UInt8.self),
            firstCount: firstCount,
            second: second?.assumingMemoryBound(to: UInt8.self),
            secondCount: secondCount
        ) else {
            // A malformed compatibility record is consumed but never reaches VT;
            // leaving it in the ring would deadlock every later record.
            return true
        }
        guard let plan = screen.planExternalOutput(record) else { return true }
        var accepted = true
        _ = TextSurfaceVTRenderer.renderExternal(
            screen: screen,
            record: record,
            plan: plan
        ) { byte in
            if accepted { accepted = consoleWriteBuffered(byte) }
        }
        guard accepted, consoleFlush() else { return false }
        screen.commitExternalOutput(plan)
        return true
    }

    private mutating func sweepDeadCompatibilityClients() {
        for slot in 0..<compatibilityClients.count {
            guard let identity = compatibilityClients[slot],
                  !identityAlive(identity)
            else { continue }
            if let ring = compatibilityRings[slot] {
                _ = drainCompatibility(ring, source: identity, includingPartialLine: true)
            }
            releaseCompatibility(slot: slot)
        }
    }

    private func compatibilitySlot(for identity: UInt32) -> Int? {
        guard identity != 0 else { return nil }
        for slot in 0..<compatibilityClients.count where compatibilityClients[slot] == identity {
            return slot
        }
        return nil
    }

    private func freeCompatibilitySlot() -> Int? {
        for slot in 0..<compatibilityClients.count where compatibilityClients[slot] == nil {
            return slot
        }
        return nil
    }

    private mutating func releaseCompatibility(slot: Int) {
        if let ring = compatibilityRings[slot] {
            _ = munmap(
                addr: UInt64(UInt(bitPattern: ring.regionBase)),
                size: Self.pageSize
            )
        }
        if let grant = compatibilityGrants[slot] { _ = capDrop(grant) }
        compatibilityClients[slot] = nil
        compatibilityRings[slot] = nil
        compatibilityGrants[slot] = nil
    }

    private mutating func registerSurface(_ request: inout ReceivedMessage) {
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
        let address = shmMap(handle: granted, writable: true)
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
        screen = TextSurfaceScreenModel()
        // A shell starts where the boot log left off, on the last row. Parking
        // there makes the model's cursor true and keeps what came before.
        _ = parkCursor()
        _ = emitGeometryQuery()
    }

    private func surfaceStatus(_ request: inout ReceivedMessage) {
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

    private mutating func presentSurface(_ request: inout ReceivedMessage) {
        guard let held = validated(request),
              let page = UnsafeMutableRawPointer(bitPattern: UInt(held.address))?.assumingMemoryBound(to: UInt8.self),
              let ring = ReixTextSurfaceRing(page: page, token: held.token, epoch: held.epoch)
        else {
            replyOperation(.present, status: .refused, sequence: request.message.words[0], token: 0, epoch: 0)
            return
        }
        let transaction    = request.message.words[0]
        let sourceIdentity = request.identity
        #if REIX_TERMINAL_PROFILE
        var correlation: UInt32 = 0
        var emittedBytes: UInt32 = 0
        #endif

        var response = ReixTextSurfaceStatus.refused
        var ackStatus = ReixTextSurfaceAckStatus.malformed
        var ackRevision = screen.revision
        var ackBaseRevision = screen.revision
        let result = ring.popFrame(transaction: transaction) { frame in
            #if REIX_TERMINAL_PROFILE
            correlation = frame.descriptor.correlation
            if ReixInteractionSequence.isCorrelated(correlation) {
                mark(
                    .presentationRequested,
                    correlation: correlation,
                    value: UInt32(frame.descriptor.payloadBytes)
                )
            }
            #endif
            ackRevision = frame.descriptor.revision
            ackBaseRevision = frame.descriptor.baseRevision
            guard frame.descriptor.source == 0
                    || frame.descriptor.source == sourceIdentity
            else {
                response = .refused
                ackStatus = .malformed
                return .commit
            }
            switch screen.prepare(frame) {
                case .duplicate:
                    response = .ok
                    ackStatus = .committed
                    return .commit
                case .resynchronizationRequired:
                    response = .snapshotRequired
                    ackStatus = .snapshotRequired
                    return .commit
                case .ready:
                    let metrics  = TextSurfaceVTRenderer.metrics(screen: screen, frame: frame)
                    var accepted = true
                    let rendered = TextSurfaceVTRenderer.render(
                        screen: screen,
                        frame: frame,
                        useDiff: metrics.usesDiff
                    ) { byte in
                        if accepted { accepted = consoleWriteBuffered(byte) }
                    }
                    #if REIX_TERMINAL_PROFILE
                    if ReixInteractionSequence.isCorrelated(correlation) {
                        mark(.presentationFullBytes, correlation: correlation, value: metrics.fullBytes)
                        mark(.presentationDiffBytes, correlation: correlation, value: metrics.diffBytes)
                        mark(.presentationPlan, correlation: correlation, value: metrics.usesDiff ? 1 : 0)
                    }
                    #endif
                    guard accepted, consoleFlush() else {
                        screen.requireSnapshot()
                        response = .hardwareFailure
                        ackStatus = .hardwareFailure
                        return .commit
                    }
                    guard screen.commit(frame) else {
                        screen.requireSnapshot()
                        response = .snapshotRequired
                        ackStatus = .snapshotRequired
                        return .commit
                    }
                    #if REIX_TERMINAL_PROFILE
                    emittedBytes = rendered
                    #endif
                    response = .ok
                    ackStatus = .committed
                    return .commit
            }
        }

        switch result {
            case .malformed, .incomplete:
                _ = ring.recoverMalformed()
                response = .malformed
                ackStatus = .malformed
                screen.requireSnapshot()
            case .stale:
                response = .refused
                ackStatus = .stale
            case .empty:
                response = .snapshotRequired
                ackStatus = .snapshotRequired
            case .retry:
                break
            case .committed:
                break
        }
        if let acknowledgement = ReixTextSurfaceAcknowledgement(
            status: ackStatus,
            transaction: transaction,
            revision: ackRevision,
            baseRevision: ackBaseRevision,
            token: held.token,
            epoch: held.epoch
        ) {
            _ = ring.publish(acknowledgement)
        }
        #if REIX_TERMINAL_PROFILE
        if response == .ok && ReixInteractionSequence.isCorrelated(correlation) {
            mark(.consoleAcknowledged, correlation: correlation, value: emittedBytes)
        }
        #endif
        replyOperation(.present, status: response, sequence: transaction, token: held.token, epoch: held.epoch)
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

    private func emitTerminalModes() -> Bool {
        emit(Self.escape)
        emit(Self.openBracket)
        emit(UInt8(ascii: "?"))
        emit(UInt8(ascii: "2"))
        emit(UInt8(ascii: "0"))
        emit(UInt8(ascii: "0"))
        emit(UInt8(ascii: "4"))
        emit(UInt8(ascii: "h"))

        // Preserve the text produced by every key while making modifiers on
        // Enter, Tab and Backspace observable. Unsupported terminals ignore it.
        emit(Self.escape)
        emit(Self.openBracket)
        emit(UInt8(ascii: ">"))
        emit(UInt8(ascii: "2"))
        emit(UInt8(ascii: "5"))
        emit(UInt8(ascii: "u"))
        return consoleFlush()
    }

    /// Asks the terminal how big it is. The answer arrives as an ordinary reply on
    /// the serial line and the decoder turns it into a resize event; a terminal
    /// that never answers leaves the producer on its declared default.
    private func emitGeometryQuery() -> Bool {
        emit(Self.escape)
        emit(Self.openBracket)
        emit(UInt8(ascii: "1"))
        emit(UInt8(ascii: "8"))
        emit(UInt8(ascii: "t"))
        return consoleFlush()
    }

    /// `CUP` clamps, so a row past the end is the portable way to say "the bottom"
    /// without waiting to hear how tall the terminal is.
    private func parkCursor() -> Bool {
        emit(Self.escape)
        emit(Self.openBracket)
        emit(UInt8(ascii: "9"))
        emit(UInt8(ascii: "9"))
        emit(UInt8(ascii: "9"))
        emit(UInt8(ascii: ";"))
        emit(UInt8(ascii: "1"))
        emit(UInt8(ascii: "H"))
        return consoleFlush()
    }

    private func emit(_ byte: UInt8) {
        _ = consoleWriteBuffered(byte)
    }

    private static let escape: UInt8 = 0x1B
    private static let openBracket: UInt8 = 0x5B
}
