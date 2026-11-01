//
//  FSLayout.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Where everything is on a formatted disk, and how wide it is.
///
/// One block is eight sectors, which is one call to a block device and one
/// window between a client and the disk server. That is not a coincidence to be
/// discovered later: every read here costs exactly one round trip because the
/// numbers were chosen to make it so.
public enum FSLayout {

    /// Bytes in a block. Everything below is a whole number of these.
    public static let blockSize: UInt64 = 4096

    /// `REIXFS` and two zero bytes, as the first eight bytes of a superblock.
    /// A byte, not a number, so a hex dump of the disk says what it is.
    ///
    /// No version in it. The two bytes after the name used to carry one, and a
    /// disk that still says `REIXFS01` or `REIXFS02` was laid down by an earlier
    /// build with its regions somewhere else: it is refused as unrecognised,
    /// untouched, rather than read, called corrupt, or formatted over.
    public static let magic: UInt64 = 0x0000_5346_5849_4552   // "REIXFS\0\0"

    /// The first six of those bytes on their own: whether a superblock is this
    /// system's at all.
    ///
    /// Read apart from the rest so that meeting a disk this build cannot read
    /// is not the same event as meeting a disk that holds something else. One of
    /// those is refused by name; the other is none of this system's business.
    public static let magicFamily: UInt64 = 0x5346_5849_4552  // "REIXFS"


    /// Bytes in one object record, and one directory entry.
    ///
    /// A record is twice an entry because a record carries what a container
    /// needs: how much room it may use, how much it has used, and which
    /// container it belongs to. Those three fields are what turn a folder into
    /// a place with a boundary.
    public static let objectSize: UInt64 = 128
    public static let entrySize : UInt64 = 64

    /// The longest name a directory entry holds. Everything else in an entry is
    /// eight bytes, so this is what is left.
    public static let nameLimit: Int = 56

    /// The longest name the machine itself may have, in the superblock.
    public static let machineNameLimit: Int = 24

    /// What a freshly formatted disk calls itself until somebody renames it.
    public static let defaultMachineName: StaticString = "reix"

    /// How many extents one object records before it runs out of room. A file
    /// written once on a fresh disk uses one; eight is what fits.
    public static let extentLimit: Int = 8

    /// The root of the disk is always the first object, and it is a container:
    /// the machine itself. Everything on the disk is inside it, which is what
    /// makes "see the whole disk" a capability somebody holds rather than a
    /// privilege somebody has.
    public static let rootObject: UInt32 = 0

    /// One object per this many bytes of disk, which sets how many files fit.
    /// Sixteen kilobytes each is generous for a disk this size and cheap: the
    /// whole table for 16 MiB is sixteen blocks.
    public static let bytesPerObject: UInt64 = 16384

    /// The largest disk this format is declared to work on.
    ///
    /// **Measured, not chosen.** Every walk a mount makes is now one pass over
    /// the object table at a time, so a recovery costs a few table lengths and a
    /// clean mount costs none: the seal and the bitmap. `ScaleTests` measures
    /// four geometries and this is the largest whose worst recovery stays inside
    /// the service level below.
    ///
    /// ```
    /// geometry  blocks  bmap  table  clean reads  dirty reads  dirty model  mend reads  mend model
    /// 16 MiB    4096    1     32     8            397          31ms         462         35ms
    /// 256 MiB   65536   2     512    9            1838         127ms        2864        193ms
    /// 1 GiB     262144  8     2048   17           6452         430ms        10556       702ms
    /// 2 GiB     524288  16    4096   27           12604        843ms        20812       1395ms
    /// ```
    ///
    /// **The service level.** A dirty mount runs `putRight` before it serves
    /// anything, so its cost is time a machine spends with no file system. One
    /// second is the line, against host time plus fifty microseconds per device
    /// read. `dirty` is a disk that went away with nothing to put right, which is
    /// what the journal leaves; `mend` is one with blocks nobody owns and a room
    /// behind, so the map and the room are rewritten and the whole disk is
    /// scanned again. The limit is set by the second. A clean shutdown runs the
    /// same full check before it seals, so it costs about the `dirty` column,
    /// at shutdown instead of at boot.
    ///
    /// Two gibibytes fails it: the mending recovery reads every table block five
    /// times, twenty thousand reads before the host has done anything. Past here
    /// the next cost is the name scrub, which reads each folder once per
    /// partition and so grows with how many folders a disk has, not how big it
    /// is.
    public static let maxSupportedBlocks: UInt32 = 262144

    /// How many containers a disk may hold.
    ///
    /// One page of indices, because that is what the room walk sorts them into
    /// and what the seal's quota index is sized for. A create past it is refused
    /// before it writes rather than leaving a disk no walk can check.
    public static let maxContainers: Int = Int(blockSize) / 4


    // MARK: - The front of the disk

    /// The two superblocks.
    ///
    /// Two, and never written in the same breath: one of them is always the last
    /// one that was complete. A single superblock has no state between "the old
    /// one" and "the new one" - it has a state in the middle of being written,
    /// and a power cut there used to be a disk with no readable front block at
    /// all.
    public static let superblockA: UInt32 = 0
    public static let superblockB: UInt32 = 1

    /// Where the journal says what it is holding.
    public static let journalHeaderBlock: UInt32 = 2

    /// The first of the journal's payload blocks.
    public static let journalStart: UInt32 = 3

    /// How many blocks of after-images one transaction may hold.
    ///
    /// Sixteen, which is what the operations this format has actually touch: the
    /// widest of them - a relocate, or a growth that charges a container and
    /// moves a directory entry - is a handful of blocks. An operation that would
    /// need a seventeenth is refused before it starts rather than committed in
    /// halves, because a transaction that can be truncated is not one.
    public static let journalBlocks: UInt32 = 16

    /// The first block that is not the front of the disk.
    public static let reservedBlocks: UInt32 = journalStart + journalBlocks

    /// Bytes at the front of the seal before its group summaries. See `FSSeal`.
    public static let sealHeader: UInt64 = 32

    /// How many file data checksums one block of the sum region holds: four
    /// bytes each, one for every block of the disk, indexed by block number.
    public static let sumsPerBlock: UInt64 = blockSize / 4


    /// Where each region starts, worked out from the size of the disk alone.
    ///
    /// Deliberately a calculation and not a set of stored fields, so a disk
    /// cannot claim a layout that does not add up. The superblock stores the
    /// answers anyway, and mounting checks that they match.
    public struct Plan {

        public let totalBlocks : UInt32
        public let bitmapStart : UInt32
        public let bitmapBlocks: UInt32
        public let sealStart   : UInt32
        public let sealBlocks  : UInt32
        public let tableStart  : UInt32
        public let tableBlocks : UInt32

        /// The checksum of every block of file data, between the table and the
        /// data. One per block of the disk rather than per block of data, so the
        /// address of a checksum is the block number and nothing else.
        public let sumStart    : UInt32
        public let sumBlocks   : UInt32
        public let dataStart   : UInt32
        public let objectCount : UInt32

        /// Where the journal's header and payload blocks are. Fixed by the
        /// format rather than worked out, but carried here so that nothing has
        /// to reach for two different sources when it wants an address.
        public var journalHeader: UInt32 { FSLayout.journalHeaderBlock }
        public var journalStart : UInt32 { FSLayout.journalStart }
        public var journalBlocks: UInt32 { FSLayout.journalBlocks }

        public init?(sectorCount: UInt64, sectorSize: UInt64) {

            // Asked before anything divides by it. A division by zero is a trap
            // and not a refusal, and both of these numbers came from a device
            // saying what it is: a device claiming sectors of no size would take
            // the process down rather than be turned away at the door.
            guard sectorSize > 0 else { return nil }

            // And exactly, not approximately. Truncating here would give a
            // "block" of some other size while every offset below went on being
            // computed in four-kilobyte units - which is not a refusal either,
            // it is every read landing somewhere else.
            guard FSLayout.blockSize % sectorSize == 0 else { return nil }

            let sectorsPerBlock = FSLayout.blockSize / sectorSize
            guard sectorsPerBlock > 0 else { return nil }

            let blocks = sectorCount / sectorsPerBlock

            // The front of the disk plus a bitmap block plus a table block plus
            // somewhere to put a byte. A disk smaller than its own bookkeeping is
            // refused rather than laid out into itself.
            guard blocks >= UInt64(FSLayout.reservedBlocks) + 3,
                  blocks <= UInt64(UInt32.max)
            else { return nil }

            // One bit per block.
            let bitmapBlocks = divideUp(divideUp(blocks, 8), FSLayout.blockSize)

            let objects = max(
                divideUp(blocks * FSLayout.blockSize, FSLayout.bytesPerObject),
                FSLayout.blockSize / FSLayout.objectSize
            )
            let tableBlocks = divideUp(objects * FSLayout.objectSize, FSLayout.blockSize)
            let objectCount = tableBlocks * FSLayout.blockSize / FSLayout.objectSize

            let sumBlocks = divideUp(blocks, FSLayout.sumsPerBlock)

            // A summary per bitmap block, a checksum per table and sum block, and
            // a quota index entry per container this disk could ever hold.
            let indexed    = objectCount < UInt64(FSLayout.maxContainers)
                ? objectCount : UInt64(FSLayout.maxContainers)
            let sealBlocks = divideUp(
                FSLayout.sealHeader + 8 * bitmapBlocks + 4 * (tableBlocks + sumBlocks)
                    + 8 * indexed,
                FSLayout.blockSize
            )

            let front     = UInt64(FSLayout.reservedBlocks)
            let sumStart  = front + bitmapBlocks + sealBlocks + tableBlocks
            let dataStart = sumStart + sumBlocks
            guard dataStart < blocks else { return nil }

            self.totalBlocks  = UInt32(blocks)
            self.bitmapStart  = FSLayout.reservedBlocks
            self.bitmapBlocks = UInt32(bitmapBlocks)
            self.sealStart    = UInt32(front + bitmapBlocks)
            self.sealBlocks   = UInt32(sealBlocks)
            self.tableStart   = UInt32(front + bitmapBlocks + sealBlocks)
            self.tableBlocks  = UInt32(tableBlocks)
            self.sumStart     = UInt32(sumStart)
            self.sumBlocks    = UInt32(sumBlocks)
            self.dataStart    = UInt32(dataStart)
            self.objectCount  = UInt32(objectCount)
        }
    }


    /// `value` divided by `unit`, rounded up, without ever overflowing.
    ///
    /// The obvious spelling is `(value + unit - 1) / unit`, and it wraps: a
    /// value near the top of the range overflows the addition before it ever
    /// divides. This one divides first and adds at most one, which cannot -
    /// reaching `UInt64.max` from the division needs `unit == 1`, and then the
    /// remainder is zero and the other branch is taken.
    ///
    /// It matters because this is reached with a byte offset a client chose. Every
    /// number that comes out of a message, off a disk or from a device arrives
    /// here as an ordinary integer, and Swift's ordinary integers trap. A trap in
    /// a server is that server gone, which is a client deciding to end the file
    /// system for everybody on the machine.
    static func divideUp(
        _ value: UInt64,
        _ unit: UInt64
    ) -> UInt64 {
        guard unit > 0 else { return 0 }

        let whole = value / unit
        return value % unit == 0 ? whole : whole &+ 1
    }

    static func max(
        _ a: UInt64,
        _ b: UInt64
    ) -> UInt64 { a > b ? a : b }
}
