//
//  main.swift
//  ReixOS
//

import Reix
import ReixABI

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

private func page() -> UnsafeMutablePointer<UInt8> {
    let value = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixSerialRingTransport.pageBytes)
    for index in 0..<ReixSerialRingTransport.pageBytes { value[index] = 0 }
    return value
}

private func chunk(_ byte: UInt8, sequence: UInt32 = 1) -> ReixSerialChunk {
    var value = byte
    return withUnsafePointer(to: &value) {
        ReixSerialChunk(direction: .transmit, sequence: sequence, bytes: $0, count: 1)!
    }
}

private func abi() {
    let access = ReixSerialAccess(role: .reader, channel: 1)!
    require(ReixSerialAccess(rawValue: access.rawValue) == access, "access roundtrip")
    require(ReixSerialAccess(rawValue: access.rawValue | (1 << 30)) == nil, "access reserved")
    require(ReixSerialChunk(direction: .receive, sequence: 1, bytes: nil, count: 0) == nil, "zero chunk")
    var byte: UInt8 = 42
    let record = withUnsafePointer(to: &byte) {
        ReixSerialChunk(
            direction: .receive,
            flags: [.endOfBatch],
            sequence: 7,
            bytes: $0,
            count: 1
        )!
    }
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: ReixSerialProtocol.recordBytes)
    defer { bytes.deallocate() }
    require(record.encode(into: bytes, capacity: ReixSerialProtocol.recordBytes), "encode")
    require(ReixSerialChunk.decode(UnsafePointer(bytes), length: ReixSerialProtocol.recordBytes) == record, "roundtrip")
    bytes[2] = 0
    require(
        ReixSerialChunk.decode(
            UnsafePointer(bytes),
            length: ReixSerialProtocol.recordBytes
        ) == nil,
        "direction mutation"
    )
}

private func ring() {
    let storage = page()
    defer { storage.deallocate() }
    require(ReixSerialRing.initialize(page: storage, role: .writer, token: 9), "proposal")
    require(28 % MemoryLayout<UInt32>.alignment == 0, "producer alignment")
    require(32 % MemoryLayout<UInt32>.alignment == 0, "consumer alignment")
    require(ReixSerialRing(page: storage, role: .writer, token: 9, epoch: 4) == nil, "proposal unusable")
    require(ReixSerialRing.accept(page: storage, role: .writer, token: 9, epoch: 4), "accept")
    let value = ReixSerialRing(page: storage, role: .writer, token: 9, epoch: 4)!
    var wrongByte: UInt8 = 1
    let wrong = withUnsafePointer(to: &wrongByte) {
        ReixSerialChunk(direction: .receive, sequence: 1, bytes: $0, count: 1)!
    }
    require(value.push(wrong) == .malformed, "direction mismatch")
    for index in 0..<ReixSerialRingTransport.capacity {
        require(value.push(chunk(UInt8(index), sequence: UInt32(index + 1))) == .ok, "fill")
    }
    require(value.push(chunk(0)) == .full, "full")
    for _ in 0..<ReixSerialRingTransport.capacity {
        if case .chunk = value.pop() {} else { fatalError("drain") }
    }
    if case .status(.empty) = value.pop() {} else { fatalError("empty") }
    require(value.push(chunk(1, sequence: 90)) == .ok, "wrap")
    storage[ReixSerialRingTransport.headerBytes + 14] = 1
    if case .status(.malformed) = value.pop() {} else { fatalError("malformed no pop") }
    if case .status(.malformed) = value.pop() {} else { fatalError("malformed retained") }
    storage[ReixSerialRingTransport.headerBytes + 14] = 0
    if case .chunk = value.pop() {} else { fatalError("repaired record") }
    storage[16] = 0
    require(value.push(chunk(1)) == .stale, "token corrupt")
}

private func cursorWrap() {
    let storage = page()
    defer { storage.deallocate() }
    require(ReixSerialRing.initialize(page: storage, role: .writer, token: 17), "cursor proposal")
    require(ReixSerialRing.accept(page: storage, role: .writer, token: 17, epoch: 3), "cursor accept")
    let ring = ReixSerialRing(page: storage, role: .writer, token: 17, epoch: 3)!
    let producer = UnsafeMutableRawPointer(storage.advanced(by: 28)).assumingMemoryBound(to: UInt32.self)
    let consumer = UnsafeMutableRawPointer(storage.advanced(by: 32)).assumingMemoryBound(to: UInt32.self)
    producer.pointee = UInt32.max - 2
    consumer.pointee = UInt32.max - 2
    for index in 0..<ReixSerialRingTransport.capacity {
        require(ring.push(chunk(UInt8(index), sequence: UInt32(index + 1))) == .ok, "cursor fill")
    }
    require(ring.push(chunk(0)) == .full, "cursor distance full")
    for _ in 0..<ReixSerialRingTransport.capacity {
        if case .chunk = ring.pop() {} else { fatalError("cursor drain") }
    }
    require(ring.isEmpty, "cursor distance empty")
}

private func transfer() {
    var core = SerialTransferCore()
    var values: [UInt8] = []
    var available = 1
    var firstAvailable = true
    let first = core.transfer(next: {
        guard firstAvailable else { return .status(.empty) }
        firstAvailable = false
        return .chunk(chunk(1))
    }, isEmpty: { !firstAvailable }, budget: 48, sink: { byte in
        guard available > 0 else { return false }
        available -= 1
        values.append(byte)
        return true
    })
    require(first == .ok && values == [1], "single transfer")
    var sequence: UInt32 = 1
    var secondAvailable = true
    let second = core.transfer(next: {
        guard secondAvailable else { return .status(.empty) }
        secondAvailable = false
        sequence += 1
        return .chunk(chunk(2, sequence: sequence))
    }, isEmpty: { !secondAvailable }, budget: 1, sink: { _ in false })
    require(second == .pending && core.hasPending, "backpressure")
    let third = core.transfer(
        next: { .status(.empty) },
        isEmpty: { true },
        budget: 1,
        sink: { byte in
            values.append(byte)
            return true
        }
    )
    require(third == .ok && values == [1, 2], "pending state")

    var multi = SerialTransferCore()
    var queued = 0
    var drained: [UInt8] = []
    let many = multi.transfer(next: {
        guard queued < 2 else { return .status(.empty) }
        queued += 1
        return .chunk(chunk(UInt8(queued), sequence: UInt32(queued)))
    }, isEmpty: { queued == 2 }, budget: 48, sink: { drained.append($0); return true })
    require(many == .ok && drained == [1, 2], "multiple chunks")
}

private func consoleWrap() {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 8)
    defer { storage.deallocate() }
    let ring = Ring(base: storage, regionSize: 4096)
    ring.reset()
    for index in 0..<1_900 {
        require(ring.push(UInt8(truncatingIfNeeded: index)), "console seed")
    }
    _ = ring.consumeAll { _, _ in }
    for index in 0..<200 {
        require(ring.push(UInt8(truncatingIfNeeded: index)), "console wrap")
    }
    var received: [UInt8] = []
    let accepted = ring.consumeAllChecked { first, firstCount, second, secondCount in
        let firstBytes = first.assumingMemoryBound(to: UInt8.self)
        for index in 0..<firstCount { received.append(firstBytes[index]) }
        if let second {
            let secondBytes = second.assumingMemoryBound(to: UInt8.self)
            for index in 0..<secondCount { received.append(secondBytes[index]) }
        }
        return true
    }
    require(accepted == 200, "console checked count")
    require(received.count == 200, "console checked exact")
    for index in 0..<200 {
        require(received[index] == UInt8(truncatingIfNeeded: index), "console checked order")
    }
}

private func consoleFlushOwnership() {
    let status = ConsoleStatus.afterSerialFlush(hasRing: true, flush: .pending)
    require(status == .registered, "pending serial flush keeps console ownership")
    let missing = ConsoleStatus.afterSerialFlush(hasRing: false, flush: .timedOut)
    require(missing == .unregistered, "missing console ring")
}

abi()
ring()
cursorWrap()
transfer()
consoleWrap()
consoleFlushOwnership()
print("SerialRingHarness: PASS")
