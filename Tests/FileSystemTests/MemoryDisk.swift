//
//  MemoryDisk.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import ReixABI

/// A block device made of host memory.
///
/// It exists because `BlockDevice` is a protocol: the file system was written
/// against the contract and not against a disk, so a slab of bytes conforms and
/// the whole of it can be exercised here with no kernel, no QEMU and no queue.
///
/// It counts its own traffic, which is how a test can say "this operation costs
/// one round trip" and be believed.
final class MemoryDisk: BlockDevice {

    let sectorSize : UInt64 = 512
    let sectorCount: UInt64
    let maximumRun : UInt64 = 8

    /// What a completed write means here, and it is settable because a slab of
    /// memory can honestly stand in for either kind of disk.
    ///
    /// `onFlush` by default, which is the harder of the two to get right and so
    /// the one worth being the default: it is what a real disk with a write
    /// cache says, and a test that wants the other answer says so.
    var durability: BlockDurability = .onFlush

    private let bytes: UnsafeMutableRawPointer

    private(set) var reads   = 0
    private(set) var writes  = 0
    private(set) var flushes = 0

    /// Set to refuse every request from the nth onward, for testing what the
    /// file system does when a disk stops answering half way through.
    var failFrom: Int? = nil
    private var requests = 0


    /// Refuses everything from the `nth` request after this call.
    ///
    /// Counted from now rather than from the beginning, because a test that
    /// wants to fail the third write of an *operation* should not have to know
    /// how many requests setting the fixture up already spent.
    func failAfter(_ nth: Int) {
        failFrom = requests + nth
    }


    /// Stops refusing, so that a test can look at the disk it just broke.
    func recover() {
        failFrom = nil
    }

    init(sectors: UInt64) {
        self.sectorCount = sectors
        self.bytes = UnsafeMutableRawPointer.allocate(
            byteCount: Int(sectors * 512),
            alignment: 8
        )
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: Int(sectors * 512))
    }

    deinit { bytes.deallocate() }


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
        destination.copyMemory(
            from     : bytes.advanced(by: Int(sector * sectorSize)),
            byteCount: Int(count * sectorSize)
        )
        return .ok
    }


    /// Set to make the next write land its first half and then refuse.
    ///
    /// The one state in which the medium holds neither the old block nor the new
    /// one, and so the one thing a cache in front of it cannot be right about by
    /// keeping either. A refusal that changed nothing lets a stale slot look
    /// correct; this does not.
    var tearsOneWrite = false

    func write(
        _ count: UInt64,
        to sector: UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus {

        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }
        if refuses() { return .deviceRefused }

        if tearsOneWrite {
            tearsOneWrite = false

            bytes.advanced(by: Int(sector * sectorSize)).copyMemory(
                from     : source,
                byteCount: Int(count * sectorSize) / 2
            )
            return .deviceRefused
        }

        writes += 1
        bytes.advanced(by: Int(sector * sectorSize)).copyMemory(
            from     : source,
            byteCount: Int(count * sectorSize)
        )
        return .ok
    }


    /// Nothing to do, honestly: these bytes are the medium.
    ///
    /// Counted anyway, because a test about ordering wants to know the barrier
    /// was asked for and not only that the writes came out in the right order
    /// on a device that could not have reordered them.
    func flush() -> BlockStatus {
        if refuses() { return .deviceRefused }

        flushes += 1
        return .ok
    }


    // MARK: - Several at once

    /// Deep enough to be worth pipelining, and the same depth a real client has.
    var depth: Int { BlockQueue.depth }

    /// Requests taken and not yet handed back, oldest first.
    ///
    /// **Deferred on purpose, and the bytes with them.** Doing the read inside
    /// `begin` would make every pipelined caller above look correct while never
    /// actually having two requests in flight - the illusion a probe on the real
    /// machine had to disprove once already.
    ///
    /// The read happens in `collect`, and that matters for more than tidiness: a
    /// device fills a buffer when it *finishes*, so a completion collected for
    /// the wrong request hands over stale bytes. Reading inside `begin` would
    /// refill the buffer for whatever request holds that slot now, and hide the
    /// whole class of mix-up.
    private var started: [(slot: Int, count: UInt64, sector: UInt64)] = []

    /// One block of landing space per slot, so four reads do not tread on each
    /// other. A real client's window is four pages for the same reason.
    private lazy var slots: UnsafeMutableRawPointer = {
        let room = UnsafeMutableRawPointer.allocate(
            byteCount: depth * Int(maximumRun * sectorSize),
            alignment: 8
        )
        room.initializeMemory(as: UInt8.self, repeating: 0, count: depth * Int(maximumRun * sectorSize))
        return room
    }()

    /// The most requests that were ever outstanding at once.
    ///
    /// The measurement the caller above is judged by. A pipelined loop that
    /// leaves this at one is a loop that is not pipelining.
    private(set) var highWater = 0

    func begin(_ count: UInt64, from sector: UInt64, slot: Int) -> BlockStatus {

        guard slot >= 0, slot < depth else { return .tooLong }
        guard holds(count, from: sector) else {
            return count > maximumRun ? .tooLong : .outOfRange
        }

        started.append((slot, count, sector))


        if started.count > highWater { highWater = started.count }

        return .ok
    }

    /// Set to make the next `collect` answer nothing while requests are still
    /// queued, leaving them behind.
    ///
    /// What a device that stops answering looks like from above, and the only
    /// way a caller ever exits its loop with transfers still outstanding. Without
    /// it the leftover-completion path cannot be reached at all, and a test that
    /// cannot reach a path is not testing it.
    var swallowsOneAnswer = false

    func collect() -> (slot: Int, status: BlockStatus)? {
        guard !started.isEmpty else { return nil }

        if swallowsOneAnswer {
            swallowsOneAnswer = false
            return nil
        }

        let next = started.removeFirst()

        // The bytes land now, which is when a device would have put them there.
        let status = read(next.count, from: next.sector, into: page(of: next.slot))

        return (next.slot, status)
    }

    /// How many answers are queued and uncollected.
    var uncollected: Int { started.count }

    func buffer(of slot: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(page(of: slot))
    }

    private func page(of slot: Int) -> UnsafeMutableRawPointer {
        slots.advanced(by: slot * Int(maximumRun * sectorSize))
    }

    /// Forgets the high-water mark, so one test can measure one operation.
    func resetDepth() { highWater = 0 }


    /// The raw byte at `offset`, for a test that wants to look at the disk
    /// rather than at what the file system says about it.
    func byte(at offset: Int) -> UInt8 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
    }


    /// Writes `byte` straight into the disk, behind the file system's back and
    /// without counting as traffic.
    ///
    /// What a torn write, a bad block, or another system's disk looks like from
    /// in here. It does not go through `write` on purpose: a test that damages
    /// the disk itself must not disturb the write count it is about to assert
    /// nothing was added to.
    func poke(_ byte: UInt8, at offset: Int) {
        bytes.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
    }


    /// Same, a word at a time, for the fields that are words.
    func poke(_ value: UInt64, at offset: Int) {
        bytes.storeBytes(of: value, toByteOffset: offset, as: UInt64.self)
    }

    func poke(_ value: UInt32, at offset: Int) {
        bytes.storeBytes(of: value, toByteOffset: offset, as: UInt32.self)
    }
}
