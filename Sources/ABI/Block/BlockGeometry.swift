//
//  BlockGeometry.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// Whether the numbers a device gives about itself are numbers anybody can use.
///
/// One function, next to `BlockRange` and for the same reason: the question is
/// arithmetic over three facts, so it can be asked on a host with no disk. The
/// difference between the two is what they are about - `BlockRange` asks whether
/// one request is inside a device, this asks whether the device is one that can
/// be asked at all.
///
/// A geometry arrives in a message from another process, so it is hostile until
/// this says otherwise. Each of the four refusals below is a number that looks
/// harmless and does damage further along: zero divides, zero sectors reads as
/// "everything is past the end", a sector wider than the window makes every
/// transfer refuse after the attach has already been accepted, and a size in
/// bytes past sixty-four bits traps the multiplication that a caller writes
/// without thinking about it.
public enum BlockGeometry {

    /// `true` when a device of these sectors can be reached through a window of
    /// `window` bytes.
    public static func usable(
        sectorSize : UInt64,
        sectorCount: UInt64,
        window     : UInt64
    ) -> Bool {

        guard sectorSize > 0, sectorCount > 0 else { return false }

        // At least one whole sector has to fit, or the largest run this window
        // allows is zero sectors and every transfer is refused as too long.
        guard sectorSize <= window else { return false }

        return !sectorCount.multipliedReportingOverflow(by: sectorSize).overflow
    }
}
