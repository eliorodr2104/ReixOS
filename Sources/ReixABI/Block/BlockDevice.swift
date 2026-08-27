//
//  BlockDevice.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//


/// Something that stores fixed-size sectors and can be asked for them by
/// number.
///
/// The whole point of this protocol is that the caller cannot tell, from the
/// code it writes, whether the sectors come from a driver in the same process or
/// from a server on the other side of an IPC. `BlockClient` conforms by asking a
/// server; `MemoryDisk` conforms by being a slab of bytes, which is how the file
/// system above it is tested without a disk at all.
///
/// Two methods are required and the single-sector forms come for free. That is
/// the split on purpose: a conformer has one place to get the bounds right, and
/// everything convenient is written once, here, rather than once per conformer.
public protocol BlockDevice {

    /// Bytes in one sector. Fixed by the device, not chosen by the caller.
    var sectorSize: UInt64 { get }

    // MARK: - Several at once

    /// How many reads this device will take before one of them comes back.
    ///
    /// `1` is a device that answers where it stands, and every caller of the
    /// pipelined pair below still works against it: `begin` does the read and
    /// `collect` hands it straight over. So there is one code path above, not two.
    var depth: Int { get }

    /// Starts a read of `count` sectors from `sector`, to be collected later
    /// under `slot`.
    ///
    /// Reads only, deliberately. Letting writes overlap would put the order they
    /// reach the medium in the device's hands, and that order is the whole of why
    /// a power cut here does not lose a file: no old block becomes free before
    /// the new state is down. There is nothing to gain on this machine and a
    /// silent way to lose everything.
    mutating func begin(
        _    count : UInt64,
        from sector: UInt64,
             slot  : Int
    ) -> BlockStatus

    /// One read that has finished, or nil when none has.
    mutating func collect() -> (slot: Int, status: BlockStatus)?

    /// Where `slot`'s bytes are, valid from its completion until the slot is used
    /// again.
    func buffer(of slot: Int) -> UnsafeRawPointer

    /// How many sectors the device holds.
    var sectorCount: UInt64 { get }

    /// The largest run of sectors one call may move. A driver is bounded by its
    /// queue, a client by the window it shares with the server.
    var maximumRun: UInt64 { get }

    /// What a completed write on this device has achieved.
    ///
    /// Declared rather than assumed, and it has to be: the three answers need
    /// different things from the layer above. `onFlush` means an order is
    /// something to ask for; `onCompletion` means it is already there, and
    /// asking costs a round trip that buys nothing; `unknown` means there is no
    /// order to be had on this device at all, and the layer above has to refuse
    /// rather than pick whichever of the other two suits it.
    var durability: BlockDurability { get }

    mutating func read(
        _    count      : UInt64,
        from sector     : UInt64,
        into destination: UnsafeMutableRawPointer
    ) -> BlockStatus

    mutating func write(
        _    count : UInt64,
        to   sector: UInt64,
        from source: UnsafeRawPointer
    ) -> BlockStatus

    /// Makes every write already accepted durable, and orders it before
    /// everything that comes after.
    ///
    /// Required rather than defaulted, because the honest answer differs per
    /// device and a default would answer for a device that was never asked. A
    /// disk with a write cache has real work to do here; a slab of host memory
    /// has none and says so.
    ///
    /// This is the whole of what a file system with no journal has: it can put
    /// its writes in an order, and it needs one call that makes the order true
    /// of the medium and not only of the queue.
    ///
    /// There is no per-request "write this one through" here, and that is the
    /// transport rather than an omission: virtio-blk has no force-unit-access
    /// flag on a request the way NVMe and SCSI do. Its answer to durability is
    /// this call and nothing else, so this is the only shape the abstraction
    /// can honestly have.
    mutating func flush() -> BlockStatus
}


public extension BlockDevice {

    /// One sector in.
    @inline(__always)
    mutating func read(
             sector     : UInt64,
        into destination: UnsafeMutableRawPointer
    
    ) -> BlockStatus { read(1, from: sector, into: destination) }

    /// One sector out.
    @inline(__always)
    mutating func write(
             sector: UInt64,
        from source: UnsafeRawPointer
             
    ) -> BlockStatus { write(1, to: sector, from: source) }

    /// Total bytes on the device, which is the one arithmetic every caller was
    /// about to write for itself, or nil when the device claims more than
    /// sixty-four bits of them.
    ///
    /// Optional rather than saturating. The two numbers come out of a message
    /// from another process, so their product is not this process's arithmetic
    /// to trust: Swift traps on the overflow, which turned a device claiming an
    /// impossible size into a caller that dies asking how big it is. Answering
    /// `UInt64.max` instead would be inventing a plausible size for a device
    /// that named an impossible one.
    var byteCount: UInt64? {
        let (bytes, overflowed) = sectorCount.multipliedReportingOverflow(by: sectorSize)
        return overflowed ? nil : bytes
    }

    /// Whether `count` sectors starting at `sector` are on this device and
    /// within one call's reach.
    func holds(
        _    count : UInt64,
        from sector: UInt64
    
    ) -> Bool {
        BlockRange.fits(count, from: sector, in: sectorCount, limit: maximumRun)
    }
}
