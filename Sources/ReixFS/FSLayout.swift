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

    /// `REIXFS` and a format version, as the first eight bytes of a superblock.
    /// A byte, not a number, so a hex dump of the disk says what it is.
    public static let magic: UInt64 = 0x3230_5346_5849_4552   // "REIXFS02"

    /// The first six of those bytes on their own: which format this is, without
    /// which version of it.
    ///
    /// Read apart from the version so that meeting a disk this build cannot
    /// read is not the same event as meeting a disk that holds something else.
    /// One of those is refused by name; the other is none of this system's
    /// business. Before they were split, both were "not formatted".
    public static let magicFamily: UInt64 = 0x5346_5849_4552  // "REIXFS"

    /// The two bytes after the family: the version of the format this build
    /// writes, and the only one it will mount.
    ///
    /// `02` is the layout with two superblocks and a journal in front of the
    /// bitmap. A `01` disk is refused by name rather than mounted or erased:
    /// the regions moved, so every offset in it means something else.
    public static let formatVersion: UInt16 = 0x3230          // "02"

    /// The family and the version of whatever is in a superblock's magic.
    public static func magicParts(_ magic: UInt64) -> (family: UInt64, version: UInt16) {
        (
            magic & 0x0000_FFFF_FFFF_FFFF,
            UInt16(truncatingIfNeeded: magic >> 48)
        )
    }

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

    /// The largest disk this version of the format is declared to work on.
    ///
    /// **Measured, not chosen.** A scan of the block map reads the whole object
    /// table once per bitmap block, so it costs bitmap blocks times table blocks,
    /// and both grow with the disk: the walk is quadratic. `ScaleTests` measures
    /// three geometries and this is the largest whose recovery stays inside the
    /// service level below.
    ///
    /// ```
    /// geometry  blocks   bmap  table   recover reads  recover p50
    /// 16 MiB    4096     1     32      227            21ms
    /// 256 MiB   65536    2     512     4613           412ms
    /// 1 GiB     262144   8     2048    not served     not measured
    /// ```
    ///
    /// **The service level.** A dirty mount runs `putRight` before it serves
    /// anything, so its cost is time a machine spends with no file system. One
    /// second is the line: long enough that the walk is allowed to be a walk,
    /// short enough that a boot is not visibly waiting for the disk.
    ///
    /// A gibibyte fails it by the measured model before it is served: the dirty
    /// path would make at least `(2 * 8 + 5) * 2048 = 43,008` table reads before
    /// its bounded metadata overhead. At fifty microseconds per device read that
    /// alone is more than two seconds. Two hundred and fifty-six mebibytes made
    /// 4,613 reads and a 412ms host median in `ScaleTests`; its device latency
    /// remains inside the one-second target with the tested 50us model.
    ///
    /// Past this the answer is not a slower mount, it is a different format:
    /// block-group summaries so the map can be checked a group at a time instead
    /// of against the whole table, and a persistent quota index so the room walk
    /// needs no pass at all. Both are v03, and both are refusals here rather than
    /// promises: a geometry nobody has measured is not one this build accepts.
    public static let maxSupportedBlocksV02: UInt32 = 65536


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


    /// Where each region starts, worked out from the size of the disk alone.
    ///
    /// Deliberately a calculation and not a set of stored fields, so a disk
    /// cannot claim a layout that does not add up. The superblock stores the
    /// answers anyway, and mounting checks that they match.
    public struct Plan {

        public let totalBlocks : UInt32
        public let bitmapStart : UInt32
        public let bitmapBlocks: UInt32
        public let tableStart  : UInt32
        public let tableBlocks : UInt32
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

            let front     = UInt64(FSLayout.reservedBlocks)
            let dataStart = front + bitmapBlocks + tableBlocks
            guard dataStart < blocks else { return nil }

            self.totalBlocks  = UInt32(blocks)
            self.bitmapStart  = FSLayout.reservedBlocks
            self.bitmapBlocks = UInt32(bitmapBlocks)
            self.tableStart   = UInt32(front + bitmapBlocks)
            self.tableBlocks  = UInt32(tableBlocks)
            self.dataStart    = UInt32(dataStart)
            self.objectCount  = UInt32(tableBlocks * FSLayout.blockSize / FSLayout.objectSize)
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
