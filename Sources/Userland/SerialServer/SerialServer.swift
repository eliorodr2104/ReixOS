//
//  SerialServer.swift
//  ReixOS
//

import Reix
import ReixABI

/// The raw UART service. It deliberately has no console dependency at boot.
public struct SerialServer: Service {
    public static let manifest = ServiceManifest(provides: .parent)

    private static let pageBytes: UInt64 = 4096
    private static let receiveWaitMilliseconds: UInt64 = 50
    private static let transmitBudget = ReixSerialRingTransport.capacity
        * ReixSerialProtocol.maximumPayload

    private let endpoint: UInt32
    private let uartBase: UnsafeMutableRawPointer
    private let interrupt: UInt32
    private var reader = SerialBinding()
    private var writer = SerialBinding()
    private var transmitter = SerialTransferCore()
    private var receiveSequence: UInt32 = 1
    private var nextReaderEpoch: UInt64 = 1
    private var nextWriterEpoch: UInt64 = 1

    public var serviceEndpoint: UInt32 { endpoint }

    public init(environment: Environment, endpoint: UInt32) {
        self.endpoint = endpoint
        guard let device = environment.device,
              let interrupt = environment.interrupt,
              let mapped = UnsafeMutableRawPointer(bitPattern: UInt(mapDevice(handle: device)))
        else { exit(code: 1) }
        self.uartBase = mapped
        self.interrupt = interrupt
        pl011EnableReceive(mapped)
    }

    public mutating func handle(_ operation: ReixSerialServerOperation, request: inout ReceivedMessage) {
        sweep()
        guard let access = ReixSerialAccess(rawValue: request.session), access.channel == 1 else {
            replyStatus(operation, .refused)
            return
        }
        switch operation {
            case .registerReader:
                register(role: .reader, access: access, request: &request)
            case .registerWriter:
                register(role: .writer, access: access, request: &request)
            case .read:
                read(access: access, request: request)
            case .write:
                write(access: access, request: request)
            case .status:
                status(access: access, request: request)
        }
    }

    private mutating func register(
        role: ReixSerialRingRole,
        access: ReixSerialAccess,
        request: inout ReceivedMessage
    ) {
        guard (role == .reader && access.role == .reader) || (role == .writer && access.role == .writer),
              request.identity != 0,
              request.message.tag.length == 2,
              request.message.words[0] != 0,
              let offered = request.grantedCap,
              shmPages(handle: offered) == 1,
              let page = UnsafeMutableRawPointer(
                bitPattern: UInt(shmMap(handle: offered))
              )?.assumingMemoryBound(to: UInt8.self)
        else {
            replyStatus(role == .reader ? .registerReader : .registerWriter, .malformed)
            return
        }
        if role == .writer, transmitter.hasPending {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: Self.pageBytes)
            replyStatus(role == .reader ? .registerReader : .registerWriter, .pending)
            return
        }
        let epoch = nextEpoch(for: role)
        guard ReixSerialRing.accept(page: page, role: role, token: request.message.words[0], epoch: epoch) else {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: Self.pageBytes)
            replyStatus(role == .reader ? .registerReader : .registerWriter, .malformed)
            return
        }
        guard let grant = request.takeGrant() else {
            _ = munmap(addr: UInt64(UInt(bitPattern: page)), size: Self.pageBytes)
            replyStatus(role == .reader ? .registerReader : .registerWriter, .refused)
            return
        }
        let fresh = SerialBinding(
            identity: request.identity,
            token: request.message.words[0],
            epoch: epoch,
            page: page,
            grant: grant
        )
        if role == .reader {
            let old = reader
            reader = fresh
            release(old)
        } else {
            let old = writer
            writer = fresh
            transmitter = SerialTransferCore()
            release(old)
        }
        replyStatus(role == .reader ? .registerReader : .registerWriter, .ok)
    }

    private mutating func read(access: ReixSerialAccess, request: ReceivedMessage) {
        guard valid(request: request, access: access, binding: reader, role: .reader),
              let ring = reader.ring(role: .reader)
        else {
            replyStatus(.read, .stale)
            return
        }
        let result = drainReceive(into: ring)
        replyStatus(.read, result)
    }

    private mutating func write(access: ReixSerialAccess, request: ReceivedMessage) {
        guard valid(request: request, access: access, binding: writer, role: .writer),
              let ring = writer.ring(role: .writer)
        else {
            replyStatus(.write, .stale)
            return
        }
        replyStatus(.write, transmit(from: ring))
    }

    private func status(access: ReixSerialAccess, request: ReceivedMessage) {
        let binding = access.role == .reader ? reader : writer
        let known = binding.identity == request.identity
            && binding.identity != 0
            && binding.token == request.message.words[0]
            && request.message.tag.length == 3
        replyStatus(.status, known ? .ok : .stale, token: known ? binding.token : 0, epoch: known ? binding.epoch : 0)
    }

    private mutating func drainReceive(into ring: ReixSerialRing) -> ReixSerialStatus {
        guard !ring.isFull else { return .full }
        var bytes = InlineArray<48, UInt8>(repeating: 0)
        var count = drainBytes(into: &bytes)
        if count == 0 {
            let fired = irqWait(handle: interrupt, ticks: deadlineTicks())
            guard fired != 0, fired != UInt64.max else { return .timedOut }
            count = drainBytes(into: &bytes)
            pl011ClearReceive(uartBase)
            _ = irqAck(handle: interrupt, bits: fired)
        }
        guard count > 0 else { return .empty }
        let result = ReixSerialChunk(
            direction: .receive,
            sequence: receiveSequence,
            payload: bytes,
            count: count
        ).map { ring.push($0) } ?? .malformed
        if result == .ok { receiveSequence = receiveSequence == UInt32.max ? 1 : receiveSequence + 1 }
        return result
    }

    private func drainBytes(into bytes: inout InlineArray<48, UInt8>) -> Int {
        var count = 0
        while count < ReixSerialProtocol.maximumPayload {
            let byte = pl011TryReadByte(uartBase)
            guard byte <= 0xFF else { break }
            bytes[count] = UInt8(byte)
            count += 1
        }
        return count
    }

    private mutating func transmit(from ring: ReixSerialRing) -> ReixSerialStatus {
        transmitter.transfer(
            next: { ring.pop() },
            isEmpty: { ring.isEmpty },
            budget: Self.transmitBudget,
            sink: { byte in
                // The writer ring bounds the number of bytes handled by this
                // request. PL011 forward progress remains the hardware
                // assumption: polling volatile TXFF, unlike TXIM on QEMU,
                // progresses without an unrelated RX byte.
                pl011WriteByte(uartBase, byte)
                return true
            }
        )
    }

    private func deadlineTicks() -> UInt64 {
        max(1, Self.receiveWaitMilliseconds / SchedulerABI.millisecondsPerTick)
    }

    private mutating func nextEpoch(for role: ReixSerialRingRole) -> UInt64 {
        if role == .reader {
            let epoch = nextReaderEpoch
            nextReaderEpoch = epoch == UInt64.max ? 1 : epoch + 1
            return epoch
        }
        let epoch = nextWriterEpoch
        nextWriterEpoch = epoch == UInt64.max ? 1 : epoch + 1
        return epoch
    }

    private func valid(
        request: ReceivedMessage,
        access: ReixSerialAccess,
        binding: SerialBinding,
        role: ReixSerialRingRole
    ) -> Bool {
        guard (role == .reader && access.role == .reader) || (role == .writer && access.role == .writer),
              request.message.tag.length == 3,
              binding.identity == request.identity,
              binding.token == request.message.words[0],
              binding.epoch == UInt64(request.message.words[1]) | UInt64(request.message.words[2]) << 32,
              binding.ring(role: role) != nil
        else { return false }
        return true
    }

    private mutating func sweep() {
        if reader.identity != 0, !identityAlive(reader.identity) {
            let old = reader
            reader = SerialBinding()
            release(old)
        }
        if writer.identity != 0, !identityAlive(writer.identity) {
            let old = writer
            writer = SerialBinding()
            transmitter = SerialTransferCore()
            release(old)
        }
    }

    private func release(_ binding: SerialBinding) {
        guard binding.grant != 0 else { return }
        _ = munmap(addr: UInt64(UInt(bitPattern: binding.page)), size: Self.pageBytes)
        _ = capDrop(binding.grant)
    }

    private func replyStatus(
        _ operation: ReixSerialServerOperation,
        _ status: ReixSerialStatus,
        token: UInt32 = 0,
        epoch: UInt64 = 0
    ) {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = status.rawValue
        words[1] = token
        words[2] = UInt32(truncatingIfNeeded: epoch)
        words[3] = UInt32(truncatingIfNeeded: epoch >> 32)
        _ = reply(message: Message(tag: MessageTag(operation, length: token == 0 ? 1 : 4), words: words))
    }
}

private struct SerialBinding {
    var identity: UInt32 = 0
    var token: UInt32 = 0
    var epoch: UInt64 = 0
    var page: UnsafeMutablePointer<UInt8>? = nil
    var grant: UInt32 = 0

    init() {}

    init(identity: UInt32, token: UInt32, epoch: UInt64, page: UnsafeMutablePointer<UInt8>, grant: UInt32) {
        self.identity = identity
        self.token = token
        self.epoch = epoch
        self.page = page
        self.grant = grant
    }

    func ring(role: ReixSerialRingRole) -> ReixSerialRing? {
        guard let page else { return nil }
        return ReixSerialRing(page: page, role: role, token: token, epoch: epoch)
    }
}
