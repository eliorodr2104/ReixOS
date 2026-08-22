//
//  InterruptClaims.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// Which interrupt line belongs to which userland holder.
///
/// A fixed table scanned linearly, and deliberately not an array indexed by
/// INTID. This distributor reports 288 implemented lines, so the indexed form
/// costs 2304 bytes of `.bss` forever to describe the two or three lines a
/// machine this size will ever hand out. The scan it replaces them with is at
/// most eight compares, and it runs only for an ID the dispatcher did not
/// already route statically, so the timer tick never reaches it.
///
/// ponytail: linear scan over a fixed table, sized for a handful of drivers.
/// If claimed lines ever outgrow it, the upgrade is an array indexed by INTID
/// and nothing outside this file changes.
enum InterruptClaims {

    static let capacity = 8

    private static var lines  = InlineArray<8, UInt32>(repeating: 0)
    private static var owners = InlineArray<8, UnsafeMutablePointer<InterruptSet>?>(repeating: nil)


    /// The set that claimed `line`, if any.
    ///
    /// Occupancy is `owners[i] != nil` and never `lines[i] != 0`, because zero
    /// is a legitimate INTID: it is the first software generated interrupt.
    static func owner(of line: UInt32) -> UnsafeMutablePointer<InterruptSet>? {
        for index in 0..<capacity where owners[index] != nil && lines[index] == line {
            return owners[index]
        }

        return nil
    }


    /// Records `set` as the holder of `line`. Fails when the table is full or
    /// the line already has a holder, which is what stops one driver from
    /// taking a line out from under another.
    static func claim(
           line: UInt32,
        by set : UnsafeMutablePointer<InterruptSet>
    ) -> Bool {
        guard owner(of: line) == nil else { return false }

        for index in 0..<capacity where owners[index] == nil {
            lines[index]  = line
            owners[index] = set

            return true
        }

        return false
    }


    /// Drops every claim `set` holds. Called when its last capability goes.
    static func releaseAll(of set: UnsafeMutablePointer<InterruptSet>) {
        for index in 0..<capacity where owners[index] == set {
            owners[index] = nil
            lines[index]  = 0
        }
    }
}
