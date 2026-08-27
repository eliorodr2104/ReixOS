//
//  FSRecordChecks.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Whether a record read off the disk could describe anything on this disk.
///
/// The reader in `FSRecords` does no interpreting on purpose: it turns bytes
/// into fields and nothing else. This is where the fields are asked whether they
/// add up, and it lives apart from the reader because it needs the one thing the
/// reader must not depend on - the shape of the disk it came from.
///
/// It used to clamp the extent count and leave everything else alone, which
/// meant a record whose runs pointed at block two was a record whose file read
/// and wrote the block bitmap. Nothing between the extent and the disk checked:
/// `readBlock` asks whether a block is on the device, and the bitmap is on the
/// device.
extension FSObject {

    /// `true` when every field of a live record is one this disk could hold.
    ///
    /// Only live records are asked about their *fields*. A free slot's other
    /// fields are nobody's business - nothing walks them - and demanding that
    /// they be zero would make a tidy disk a requirement rather than a
    /// consequence.
    ///
    /// The **encoding**, though, is asked about first, and before the free-slot
    /// shortcut. The reader clamps two fields so that nothing walks out of
    /// bounds - the extent count to eight, an unknown kind to `.free` - and both
    /// clamps used to be judged after this function had already decided.
    ///
    /// The kind is why the order matters. A record whose kind byte is seven
    /// arrived here looking like a free slot, took the shortcut, and was
    /// pronounced fine, so `create` would hand its slot out while the map still
    /// called its blocks used.
    func fits(_ plan: FSLayout.Plan) -> Bool {

        guard recordEncodingValid else { return false }

        guard kind != .free else { return true }

        // Belt and braces, and cheap: the clamp above makes this true, so a
        // reader that stopped clamping would be caught here rather than in a
        // loop.
        guard Int(extents) <= FSLayout.extentLimit else { return false }

        guard container < plan.objectCount, parent < plan.objectCount else { return false }

        // A container that has spent more than it was given. Nothing writing
        // this disk can make one - every charge is checked against the room left
        // first - so finding one means the disk is not the one that was written.
        guard used <= quota else { return false }

        var counted = UInt64(0)

        for index in 0..<Int(extents) {
            let run = runs[index]

            // An empty run is not a run. It would make the extent count a lie
            // and `block(at:)` walk past it silently.
            guard run.count > 0 else { return false }

            // The data region and nothing below it. This is the check whose
            // absence let a file reach the superblock, the bitmap and the
            // object table, and it is one comparison.
            guard run.start >= plan.dataStart else { return false }

            // Widened before adding, so a run that wraps is caught rather than
            // becoming a small number that passes.
            let end = UInt64(run.start) + UInt64(run.count)
            guard end <= UInt64(plan.totalBlocks) else { return false }

            // Against every run before it. Twenty-eight comparisons at the very
            // most, and what they buy is that one record cannot own a block
            // twice: the map is rebuilt from these runs, so a record overlapping
            // itself is a record that quietly corrupts the map.
            for earlier in 0..<index {
                let other = runs[earlier]

                let otherEnd = UInt64(other.start) + UInt64(other.count)

                guard end <= UInt64(other.start) || UInt64(run.start) >= otherEnd else {
                    return false
                }
            }

            counted += UInt64(run.count)
        }

        // The runs and the count have to be the same fact told twice.
        guard counted == UInt64(blocks) else { return false }

        // A size past the blocks to hold it is a size that reads off the end of
        // the runs. `block(at:)` answers nothing there and the read stops, so
        // this is not reachable damage - it is a record saying something untrue
        // about itself, which is enough.
        guard size <= UInt64(blocks) * FSLayout.blockSize else { return false }

        return true
    }
}
