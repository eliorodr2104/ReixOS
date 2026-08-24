//
//  BlockRange.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// Whether a run of sectors is one a device can be asked for.
///
/// One function, in one place, because the same question is asked three times
/// on the way to a disk: by the client before it spends a round trip, by the
/// server before it touches the device, and by the driver before it programs
/// the queue. Three copies of an overflow check is three chances to write it
/// wrong once.
public enum BlockRange {

    /// `true` when `count` sectors starting at `sector` are all on a device of
    /// `sectorCount` sectors, and `count` is within `limit`.
    ///
    /// The addition is deliberately wrapping and then checked, because the
    /// dangerous request is exactly the one that overflows: `sector` near the
    /// top of the range with a `count` that carries it round to a small number,
    /// which every naive `sector + count <= sectorCount` accepts.
    public static func fits(
        _    count      : UInt64,
        from sector     : UInt64,
        in   sectorCount: UInt64,
             limit      : UInt64
    ) -> Bool {

        guard count > 0, count <= limit else { return false }

        let end = sector &+ count
        return end > sector && end <= sectorCount
    }
}
