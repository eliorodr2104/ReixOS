//
//  FSSeal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 31/10/2026.
//

/// What a clean shutdown says the disk holds, so the next mount can believe it
/// instead of walking it.
///
/// Written by `unmount`, after one pass over the object table has found the
/// volume adding up, and before the clean mark that names it by checksum. A
/// superblock that is not clean names no seal, so the region means nothing from
/// the first write of a mount until the next clean shutdown. That is why none of
/// it is journalled: there is no moment at which a mount trusts a seal a power
/// cut could have left half written.
///
/// Four parts, end to end across the region, in the byte order every other
/// structure on this disk uses:
///
/// ```
/// header           32 bytes   magic, generation, groups, tables, containers
/// group summaries  8 x groups  checksum and used count of each bitmap block
/// table checksums  4 x tables  checksum of each object table block, then of
///                              each block of the sum region after it
/// quota index      8 x boxes   each container's object number and its used,
///                              ascending, the machine's root first
/// ```
///
/// A group is the run of blocks one bitmap block accounts for. Its summary is
/// what lets a mount check the map a block at a time without the table, and the
/// table checksums are what let every later read of the table, and of the file
/// data checksums, check itself. Those of the sum region must also add up to
/// the superblock's root, which costs no read of the region. The
/// quota index is the room walk's answer, kept, so that neither the mount nor
/// the first container made after it has to walk the table to know it.
enum FSSeal {

    /// `RXSEAL` and two zero bytes, so a hex dump of the region says what it is.
    static let magic: UInt64 = 0x0000_4C41_4553_5852

    /// Where each header field lives.
    enum Header {
        static let magic      = 0
        static let generation = 8
        static let groups     = 16
        static let tables     = 20
        static let containers = 24
    }

    /// Where the group summaries, the table checksums and the quota index begin,
    /// in bytes from the start of the region.
    static func groupOffset(_ group: Int) -> Int {
        Int(FSLayout.sealHeader) + 8 * group
    }

    static func tableOffset(_ table: Int, groups: Int) -> Int {
        groupOffset(groups) + 4 * table
    }

    static func indexOffset(_ entry: Int, groups: Int, tables: Int) -> Int {
        tableOffset(tables, groups: groups) + 8 * entry
    }
}
