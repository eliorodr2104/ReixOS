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

    /// `REIXFS` and a format version, as the first eight bytes of block zero.
    /// A byte, not a number, so a hex dump of the disk says what it is.
    public static let magic: UInt64 = 0x3130_5346_5849_4552   // "REIXFS01"

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
    public static let formatVersion: UInt16 = 0x3130          // "01"

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
            guard blocks >= 8, blocks <= UInt64(UInt32.max) else { return nil }

            // One bit per block.
            let bitmapBlocks = divideUp(divideUp(blocks, 8), FSLayout.blockSize)

            let objects = max(
                divideUp(blocks * FSLayout.blockSize, FSLayout.bytesPerObject),
                FSLayout.blockSize / FSLayout.objectSize
            )
            let tableBlocks = divideUp(objects * FSLayout.objectSize, FSLayout.blockSize)

            let dataStart = 1 + bitmapBlocks + tableBlocks
            guard dataStart < blocks else { return nil }

            self.totalBlocks  = UInt32(blocks)
            self.bitmapStart  = 1
            self.bitmapBlocks = UInt32(bitmapBlocks)
            self.tableStart   = UInt32(1 + bitmapBlocks)
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
