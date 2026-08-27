//
//  CrashDisk.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import ReixABI

/// A block device that loses power.
///
/// `MemoryDisk` is the medium: a write lands and stays. That is the wrong model
/// for asking what a power cut does, because it makes every ordering rule true by
/// construction. This one keeps two images instead: what is on the medium, and
/// what the device has merely *accepted*. A write goes into the queue; `flush`
/// is the only thing that moves the queue onto the medium; and `powerCut` throws
/// away whatever the queue still held.
///
/// The queue is where the interesting cases are, and they are not all "lose
/// everything". A real device with a volatile cache may land any subset of what
/// it holds, in any order, so the cut takes a **policy**: a prefix, a suffix, one
/// write on its own, or the whole queue in a different order. Every one of them
/// is deterministic, because a crash test that cannot be repeated is an anecdote.
final class CrashDisk: BlockDevice {

    let sectorSize : UInt64 = 512
    let sectorCount: UInt64
    let maximumRun : UInt64 = 8

    /// A write is accepted when its request completes and on the medium when a
    /// flush completes, which is what this whole type is for.
    let durability: BlockDurability = .onFlush

    /// What is on the medium.
    private let stable: UnsafeMutableRawPointer

    /// One accepted write, not yet on the medium.
    private struct Pending {
        let sector: UInt64
        let count : UInt64
        var bytes : [UInt8]
    }

    private var queue: [Pending] = []

    private(set) var reads   = 0
    private(set) var writes  = 0
    private(set) var flushes = 0

    /// How many writes the queue is holding.
    var accepted: Int { queue.count }


    init(sectors: UInt64) {
        self.sectorCount = sectors
        self.stable = UnsafeMutableRawPointer.allocate(
            byteCount: Int(sectors * 512),
            alignment: 8
        )
        stable.initializeMemory(as: UInt8.self, repeating: 0, count: Int(sectors * 512))
    }

    /// A device holding the same medium as `other` and nothing in its queue.
    ///
    /// What a machine sees when it boots after the crash: the bytes that reached
    /// the disk, and no memory of anything else. Every test remounts through one
    /// of these rather than reusing the instance that crashed, because reusing it
    /// would carry the file system's own cached blocks across the power cut.
    init(restarting other: CrashDisk) {
        self.sectorCount = other.sectorCount
        self.stable = UnsafeMutableRawPointer.allocate(
            byteCount: Int(other.sectorCount * 512),
            alignment: 8
        )
        stable.copyMemory(from: other.stable, byteCount: Int(other.sectorCount * 512))
    }

    deinit { stable.deallocate() }


    // MARK: - Losing power

    /// Which of the accepted writes reached the medium after all.
    enum Survivors {

        /// None of them. The plainest cut, and the one a barrier is supposed to
        /// make safe.
        case nothing

        /// All of them, in the order they were made. What a flush would have
        /// done, arriving by luck instead.
        case everything

        /// The first `n`, in order. A device draining its cache from the front.
        case forwardPrefix(Int)

        /// The last `n`, in order. A device that had reordered its cache and
        /// drained the newest first.
        case reversePrefix(Int)

        /// Exactly one, and nothing else. The narrowest thing that can go wrong,
        /// and the one that finds an ordering rule that only holds in bulk.
        case single(Int)

        /// All of them, in a deterministic order that is not the order they were
        /// made in. Two writes to one block land in the wrong sequence, which is
        /// what a cache with no barrier is allowed to do.
        case permuted(UInt64)
    }


    /// Loses power, keeping whichever accepted writes `survivors` names.
    ///
    /// The queue is empty afterwards either way: a machine that has lost power
    /// has no cache.
    func powerCut(keeping survivors: Survivors = .nothing) {
        let held = queue
        queue = []

        switch survivors {
            case .nothing:
                return

            case .everything:
                for write in held { land(write) }

            case .forwardPrefix(let many):
                for index in 0..<min(max(many, 0), held.count) { land(held[index]) }

            case .reversePrefix(let many):
                let keep = min(max(many, 0), held.count)
                for index in (held.count - keep)..<held.count { land(held[index]) }

            case .single(let which):
                guard which >= 0, which < held.count else { return }
                land(held[which])

            case .permuted(let seed):
                for index in Self.permutation(of: held.count, seed: seed) {
                    land(held[index])
                }
        }
    }


    /// A deterministic reordering of `count` indices.
    ///
    /// A multiplicative step over a prime-sized ring rather than a shuffle, so
    /// the order is a function of the seed alone and a failing case can be
    /// written down and run again.
    static func permutation(of count: Int, seed: UInt64) -> [Int] {
        guard count > 1 else { return Array(0..<count) }

        var order = Array(0..<count)
        var state = seed | 1

        // One pass of Fisher-Yates over a linear congruential sequence. Not a
        // good generator and not meant to be: it has to be repeatable, not
        // random.
        for index in stride(from: count - 1, to: 0, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let pick = Int((state >> 33) % UInt64(index + 1))

            order.swapAt(index, pick)
        }

        return order
    }


    /// The medium as it stands, for a test that wants to compare two moments.
    func snapshot() -> [UInt8] {
        let bytes = stable.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: Int(sectorCount * 512)))
    }

    /// The raw byte at `offset`, on the medium and not in the queue.
    func byte(at offset: Int) -> UInt8 {
        stable.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
    }

    /// Writes straight onto the medium, behind everybody's back. What another
    /// system's disk, or a torn write, looks like from in here.
    func poke(_ byte: UInt8, at offset: Int) {
        stable.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
    }

    func poke(_ value: UInt32, at offset: Int) {
        stable.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }


    private func land(_ write: Pending) {
        write.bytes.withUnsafeBufferPointer { buffer in
            stable.advanced(by: Int(write.sector * sectorSize)).copyMemory(
                from     : UnsafeRawPointer(buffer.baseAddress!),
                byteCount: Int(write.count * sectorSize)
            )
        }
    }


    // MARK: - The device

    /// Set to refuse every request from the nth onward.
    var failFrom: Int? = nil
    private var requests = 0

    func failAfter(_ nth: Int) { failFrom = requests + nth }
    func recover() { failFrom = nil }

    private func refuses() -> Bool {
        requests += 1
        guard let failFrom else { return false }
        return requests >= failFrom
    }


    func read(
        _ count: UInt64,
        from sector: UInt64,
        into destination: UnsafeMutableRawPointer
    ) -> BlockStatus {

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }
        if refuses() { return .deviceRefused }

        reads += 1

        // The medium first, then anything the queue holds over the top of it.
        // A device answers a read from its cache, so a write this disk has
        // accepted is a write this disk can read back - and losing power
        // afterwards is what makes it disappear again.
        destination.copyMemory(
            from     : stable.advanced(by: Int(sector * sectorSize)),
            byteCount: Int(count * sectorSize)
        )

        for write in queue { overlay(write, onto: destination, sector: sector, count: count) }

        return .ok
    }


    func write(
        _ count: UInt64,
        to sector: UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus {

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }
        if refuses() { return .deviceRefused }

        writes += 1

        let bytes = source.assumingMemoryBound(to: UInt8.self)
        queue.append(Pending(
            sector: sector,
            count : count,
            bytes : Array(UnsafeBufferPointer(start: bytes, count: Int(count * sectorSize)))
        ))

        return .ok
    }


    /// Everything accepted so far reaches the medium, in the order it was
    /// accepted.
    func flush() -> BlockStatus {
        if refuses() { return .deviceRefused }

        flushes += 1

        for write in queue { land(write) }
        queue = []

        return .ok
    }


    /// The part of `write` that falls inside `[sector, sector + count)`.
    private func overlay(
        _ write: Pending,
        onto destination: UnsafeMutableRawPointer,
        sector: UInt64,
        count : UInt64
    ) {
        let from = max(write.sector, sector)
        let to   = min(write.sector + write.count, sector + count)
        guard from < to else { return }

        write.bytes.withUnsafeBufferPointer { buffer in
            destination
                .advanced(by: Int((from - sector) * sectorSize))
                .copyMemory(
                    from     : UnsafeRawPointer(buffer.baseAddress!)
                        .advanced(by: Int((from - write.sector) * sectorSize)),
                    byteCount: Int((to - from) * sectorSize)
                )
        }
    }


    // MARK: - Several at once

    /// One at a time. Depth is the block server's business and a crash test has
    /// no use for it: what matters here is the order writes reach the medium,
    /// and reads never overlap in this format anyway.
    var depth: Int { 1 }

    private var started: [(slot: Int, count: UInt64, sector: UInt64)] = []

    private lazy var slots: UnsafeMutableRawPointer = {
        let room = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maximumRun * sectorSize),
            alignment: 8
        )
        room.initializeMemory(as: UInt8.self, repeating: 0, count: Int(maximumRun * sectorSize))
        return room
    }()

    func begin(_ count: UInt64, from sector: UInt64, slot: Int) -> BlockStatus {
        guard slot == 0 else { return .tooLong }
        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }

        started.append((slot, count, sector))
        return .ok
    }

    func collect() -> (slot: Int, status: BlockStatus)? {
        guard !started.isEmpty else { return nil }

        let next = started.removeFirst()
        let status = read(next.count, from: next.sector, into: slots)

        return (next.slot, status)
    }

    func buffer(of slot: Int) -> UnsafeRawPointer { UnsafeRawPointer(slots) }
}
