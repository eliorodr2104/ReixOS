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
    require(MemoryLayout<ReixSerialPayload>.size == 48, "scalar payload size")
    require(MemoryLayout<ReixSerialPayload>.stride == 48, "scalar payload stride")
    let access = ReixSerialAccess(role: .reader, channel: 1)!
    require(ReixSerialAccess(rawValue: access.rawValue) == access, "access roundtrip")
    require(ReixSerialAccess(rawValue: access.rawValue | (1 << 30)) == nil, "access reserved")
    require(ReixSerialChunk(direction: .receive, sequence: 1, bytes: nil, count: 0) == nil, "zero chunk")
    var byte: UInt8 = 42
    withUnsafePointer(to: &byte) {
        require(ReixSerialPayload(bytes: $0, count: -1) == nil, "negative payload count")
        require(ReixSerialPayload(bytes: $0, count: 49) == nil, "oversized payload count")
    }
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

    let fullPayload = (0..<ReixSerialProtocol.maximumPayload).map {
        UInt8(truncatingIfNeeded: $0 &* 37 &+ 11)
    }
    let fullRecord = fullPayload.withUnsafeBufferPointer {
        ReixSerialChunk(
            direction: .transmit,
            sequence: 8,
            bytes: $0.baseAddress!,
            count: $0.count
        )!
    }
    require(
        fullRecord.encode(into: bytes, capacity: ReixSerialProtocol.recordBytes),
        "full payload encode"
    )
    let fullRoundtrip = ReixSerialChunk.decode(
        UnsafePointer(bytes),
        length: ReixSerialProtocol.recordBytes
    )!
    require(fullRoundtrip == fullRecord, "full scalar payload roundtrip")
    for index in fullPayload.indices {
        require(fullRoundtrip.payload[index] == fullPayload[index], "full scalar payload byte")
    }

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

    var bounded = SerialTransferCore()
    var produced = 0
    var complete: [UInt8] = []
    let boundedResult = bounded.transfer(next: {
        guard produced < ReixSerialRingTransport.capacity else { return .status(.empty) }
        let byte = UInt8(truncatingIfNeeded: produced)
        produced += 1
        return .chunk(chunk(byte, sequence: UInt32(produced)))
    }, isEmpty: {
        produced == ReixSerialRingTransport.capacity
    }, budget: ReixSerialRingTransport.capacity * ReixSerialProtocol.maximumPayload, sink: {
        complete.append($0)
        return true
    })
    require(boundedResult == .ok, "bounded blocking transfer completes")
    require(complete.count == ReixSerialRingTransport.capacity, "bounded transfer owns every byte")
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
    require(status == .pending, "pending serial flush stays distinguishable")
    require(ConsoleStatus.afterSerialFlush(hasRing: true, flush: .ok) == .registered, "serial flush ack")
    require(ConsoleStatus.afterSerialFlush(hasRing: true, flush: .timedOut) == .failed, "serial flush failure")
    let missing = ConsoleStatus.afterSerialFlush(hasRing: false, flush: .timedOut)
    require(missing == .unregistered, "missing console ring")
}

/// A peer that writes cursors no honest producer writes.
///
/// The region is bordered with a canary so that an index escaping the window
/// would be visible here rather than merely unlikely. Every case has to end in
/// a defined refusal and an intact border.
private func hostileSerial() {
    let guardBytes = 256
    let total      = ReixSerialRingTransport.pageBytes + 2 * guardBytes
    let block      = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
    defer { block.deallocate() }
    for index in 0..<total { block[index] = 0x5A }

    let storage = block.advanced(by: guardBytes)
    for index in 0..<ReixSerialRingTransport.pageBytes { storage[index] = 0 }

    func borderIntact() -> Bool {
        for index in 0..<guardBytes where block[index] != 0x5A { return false }
        for index in 0..<guardBytes
        where block[guardBytes + ReixSerialRingTransport.pageBytes + index] != 0x5A { return false }
        return true
    }

    require(ReixSerialRing.initialize(page: storage, role: .writer, token: 31), "hostile proposal")
    require(ReixSerialRing.accept(page: storage, role: .writer, token: 31, epoch: 5), "hostile accept")
    let ring = ReixSerialRing(page: storage, role: .writer, token: 31, epoch: 5)!
    require(ring.push(chunk(7)) == .ok, "hostile seed")

    let producer = UnsafeMutableRawPointer(storage.advanced(by: 28)).assumingMemoryBound(to: UInt32.self)
    let consumer = UnsafeMutableRawPointer(storage.advanced(by: 32)).assumingMemoryBound(to: UInt32.self)

    // A producer further ahead than the ring can hold. The pair is refused
    // whole, so no slot index is ever computed from it.
    producer.pointee = UInt32(ReixSerialRingTransport.capacity) + 1
    consumer.pointee = 0
    if case .status(let stale) = ring.pop() {
        require(stale == .stale, "a cursor pair wider than the ring is stale")
    } else { fatalError("a cursor pair wider than the ring was consumed") }
    require(ring.push(chunk(8)) == .stale, "a wide pair refuses a push too")
    require(ring.freeSlots == nil, "a wide pair has no free slot count")
    require(borderIntact(), "border intact after a wide cursor pair")

    // The widest pair there is, and a consumer ahead of its producer: the same
    // answer, because it is the difference that is checked.
    producer.pointee = UInt32.max
    consumer.pointee = 0
    if case .status(let stale) = ring.pop() {
        require(stale == .stale, "the widest cursor pair is stale")
    } else { fatalError("the widest cursor pair was consumed") }
    producer.pointee = 0
    consumer.pointee = 9
    if case .status(let stale) = ring.pop() {
        require(stale == .stale, "a consumer ahead of its producer is stale")
    } else { fatalError("a consumer ahead of its producer was consumed") }
    require(borderIntact(), "border intact after a wrapped pair")

    // A window handed to a new session: the epoch in the header no longer
    // matches the one this side was told, so nothing in it is read as data.
    producer.pointee = 1
    consumer.pointee = 0
    let stalePage = UnsafeMutableRawPointer(storage.advanced(by: 16)).assumingMemoryBound(to: UInt32.self)
    stalePage.pointee = 99
    if case .status(let stale) = ring.pop() {
        require(stale == .stale, "a rewritten epoch is stale")
    } else { fatalError("a rewritten epoch was consumed") }
    require(ReixSerialRing(page: storage, role: .writer, token: 31, epoch: 5) == nil, "a stale header builds no ring")
    require(borderIntact(), "border intact after a rewritten epoch")
}


/// The console ring under the same treatment.
///
/// It has no token and no epoch, so the guarantee is narrower and worth
/// stating: every index is masked at the load, so a forged `head` or `tail`
/// buys a wrong byte count and never a read outside the window.
private func hostileConsole() {
    let regionBytes = 4096
    let guardBytes  = 256
    let total       = regionBytes + 2 * guardBytes
    let block       = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
    defer { block.deallocate() }
    for index in 0..<total { block[index] = 0x5A }

    let storage = UnsafeMutableRawPointer(block.advanced(by: guardBytes))
    for index in 0..<regionBytes { storage.storeBytes(of: UInt8(0), toByteOffset: index, as: UInt8.self) }

    func borderIntact() -> Bool {
        for index in 0..<guardBytes where block[index] != 0x5A { return false }
        for index in 0..<guardBytes
        where block[guardBytes + regionBytes + index] != 0x5A { return false }
        return true
    }

    let ring = Ring(base: storage, regionSize: regionBytes)
    ring.reset()
    for index in 0..<64 { require(ring.push(UInt8(truncatingIfNeeded: index)), "hostile console seed") }

    // Indices no producer of this ring would publish.
    storage.storeBytes(of: UInt32.max, toByteOffset: 0, as: UInt32.self)
    storage.storeBytes(of: UInt32.max - 7, toByteOffset: 4, as: UInt32.self)

    require(ring.count < regionBytes, "a forged pair cannot claim more than the window")

    var spansInside = true
    let taken = ring.consumeAll { bytes, count in
        let low  = UInt(bitPattern: bytes)
        let base = UInt(bitPattern: storage)
        if low < base + 8 || low + UInt(count) > base + UInt(regionBytes) { spansInside = false }
    }
    require(spansInside, "every span handed out is inside the window")
    require(taken < regionBytes, "a forged pair cannot hand out more than the window")
    require(borderIntact(), "border intact after forged console indices")

    // And the line scan terminates on them rather than walking off the end.
    storage.storeBytes(of: UInt32.max, toByteOffset: 0, as: UInt32.self)
    storage.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
    _ = ring.nextLineLength()
    _ = ring.consumeLine { _, _ in }
    require(borderIntact(), "border intact after a forged line scan")
}


abi()
ring()
cursorWrap()
transfer()
consoleWrap()
consoleFlushOwnership()
hostileSerial()
hostileConsole()
print("SerialRingHarness: PASS")
