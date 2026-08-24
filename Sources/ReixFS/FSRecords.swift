//
//  FSRecords.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI


/// One object: what it is, how big, when, and where its bytes are.
///
/// `FSLayout.objectSize` bytes, fixed: the fields below up to byte 52, then the
/// eight runs from byte 64. No name, because a name is not a property of a
/// thing: it is one folder's way of reaching it. And no permission bits, which
/// is the whole design in one absence.
public struct FSObject {

    public var kind    : FSKind
    public var extents : UInt8
    public var flags   : UInt16
    public var blocks  : UInt32
    public var size    : UInt64
    public var created : UInt64
    public var modified: UInt64

    /// Blocks this container may hold, and blocks it is holding. Meaningful on
    /// a container and zero on everything else.
    ///
    /// A container's room is not a fraction of the disk: it is a number given to
    /// it by whoever made it, out of that one's own. Space is delegated downward
    /// the same way authority is, and for the same reason.
    public var quota: UInt32
    public var used : UInt32

    /// How much of this container's room is still to be had.
    ///
    /// Not `quota - used`, which traps for a record that says it has spent more
    /// than it was given. Nothing writing this disk can produce one - every
    /// charge checks first - but a disk that was damaged can, and the difference
    /// between a refusal and a trap is the difference between one request
    /// failing and the file system going away.
    public var roomLeft: UInt32 { quota > used ? quota - used : 0 }

    /// The container this object is charged to.
    ///
    /// On a file or a folder, the container whose room its blocks come out of.
    /// On a container, the container it sits inside. The two meanings are one
    /// walk: following this field upward from anything reaches the machine's
    /// root, and that walk is the whole containment check.
    public var container: UInt32

    /// The folder that names this object.
    ///
    /// Not the same question as `container`, and the difference is the whole
    /// reason both exist: `container` says whose room the blocks come out of,
    /// `parent` says where the thing sits. Following `parent` upward is how
    /// "is this inside that" is answered for a *folder*, which is what lets a
    /// subtree be handed to somebody rather than only a whole container.
    ///
    /// The machine's root is its own parent, and that is where every walk ends.
    public var parent: UInt32

    /// Which incarnation of this slot this record is.
    ///
    /// A table slot outlives the objects that pass through it: remove the file
    /// at slot twelve and the next `create` may well be given slot twelve. So
    /// the slot number is not an identity, and anything that hands one out and
    /// expects to mean the same thing later - a capability, above all - has to
    /// carry this too.
    ///
    /// Bumped when a slot is *released*, not when it is taken, so that a
    /// capability naming an object stops working the moment the object is
    /// removed rather than the moment its slot is handed on. It survives the
    /// slot being free, which is the only reason it can be trusted: a counter
    /// that reset with the record it lives in would count the same numbers
    /// again.
    ///
    /// It goes round eventually. Thirty-two bits is four thousand million
    /// removals of one slot, and the badge carries fewer than that - see
    /// `FSBadge`.
    public var generation: UInt32

    public var runs: InlineArray<8, FSExtent>

    public init(
        kind     : FSKind = .free,
        created  : UInt64 = 0,
        container: UInt32 = 0
    ) {
        self.kind       = kind
        self.extents    = 0
        self.flags      = 0
        self.blocks     = 0
        self.size       = 0
        self.created    = created
        self.modified   = created
        self.quota      = 0
        self.used       = 0
        self.container  = container
        self.parent     = container
        self.generation = 0
        self.runs       = InlineArray<8, FSExtent>(repeating: FSExtent())
    }


    public init(reading base: UnsafeRawPointer) {
        self.kind      = FSKind(rawValue: base.loadUnaligned(fromByteOffset: 0, as: UInt8.self)) ?? .free
        self.extents   = base.loadUnaligned(fromByteOffset: 1,  as: UInt8.self)
        self.flags     = base.loadUnaligned(fromByteOffset: 2,  as: UInt16.self)
        self.blocks    = base.loadUnaligned(fromByteOffset: 4,  as: UInt32.self)
        self.size      = base.loadUnaligned(fromByteOffset: 8,  as: UInt64.self)
        self.created   = base.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
        self.modified  = base.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        self.quota     = base.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
        self.used      = base.loadUnaligned(fromByteOffset: 36, as: UInt32.self)
        self.container = base.loadUnaligned(fromByteOffset: 40, as: UInt32.self)
        self.parent    = base.loadUnaligned(fromByteOffset: 44, as: UInt32.self)
        self.generation = base.loadUnaligned(fromByteOffset: 48, as: UInt32.self)

        var runs = InlineArray<8, FSExtent>(repeating: FSExtent())
        for index in 0..<FSLayout.extentLimit {
            let at = 64 + index * 8
            runs[index] = FSExtent(
                start: base.loadUnaligned(fromByteOffset: at,     as: UInt32.self),
                count: base.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)
            )
        }
        self.runs = runs

        // A record claiming more runs than it has room for is a corrupt record,
        // and clamping is what keeps every loop below in bounds.
        if Int(self.extents) > FSLayout.extentLimit {
            self.extents = UInt8(FSLayout.extentLimit)
        }
    }


    public func write(to base: UnsafeMutableRawPointer) {
        base.storeBytes(of: kind.rawValue, toByteOffset: 0,  as: UInt8.self)
        base.storeBytes(of: extents,       toByteOffset: 1,  as: UInt8.self)
        base.storeBytes(of: flags,         toByteOffset: 2,  as: UInt16.self)
        base.storeBytes(of: blocks,        toByteOffset: 4,  as: UInt32.self)
        base.storeBytes(of: size,          toByteOffset: 8,  as: UInt64.self)
        base.storeBytes(of: created,       toByteOffset: 16, as: UInt64.self)
        base.storeBytes(of: modified,      toByteOffset: 24, as: UInt64.self)
        base.storeBytes(of: quota,         toByteOffset: 32, as: UInt32.self)
        base.storeBytes(of: used,          toByteOffset: 36, as: UInt32.self)
        base.storeBytes(of: container,     toByteOffset: 40, as: UInt32.self)
        base.storeBytes(of: parent,        toByteOffset: 44, as: UInt32.self)
        base.storeBytes(of: generation,    toByteOffset: 48, as: UInt32.self)

        for index in 0..<FSLayout.extentLimit {
            let at = 64 + index * 8
            base.storeBytes(of: runs[index].start, toByteOffset: at,     as: UInt32.self)
            base.storeBytes(of: runs[index].count, toByteOffset: at + 4, as: UInt32.self)
        }
    }


    /// The block holding byte `offset` of this object, or nil past its end.
    ///
    /// Walking the runs is the whole address translation this format has, and
    /// four of them is a short walk.
    public func block(at offset: UInt64) -> UInt32? {

        var wanted = offset / FSLayout.blockSize

        for index in 0..<Int(extents) {
            let run = runs[index]
            
            if wanted < UInt64(run.count) {
                return run.start + UInt32(wanted)
            }
            
            wanted -= UInt64(run.count)
        }

        return nil
    }


    /// Adds `count` blocks starting at `start`, joining them onto the last run
    /// when they carry straight on from it.
    ///
    /// The joining is what keeps a file that grows a block at a time down to
    /// one run. Without it four appends would exhaust an object.
    public mutating func append(
        start: UInt32,
        count: UInt32
    ) -> Bool {

        guard count > 0 else { return false }

        // Every sum here is checked rather than trusted. The record this is
        // called on came off a disk, and a run whose end wraps past the top of
        // the range is a run that satisfies a bound it never met - and the
        // addition that finds out traps before anything gets to ask.
        let (total, tooMany) = blocks.addingReportingOverflow(count)
        guard !tooMany else { return false }

        if extents > 0 {
            let last = Int(extents) - 1
            let (end, wrapped) = runs[last].start.addingReportingOverflow(runs[last].count)

            if !wrapped, end == start {
                let (joined, over) = runs[last].count.addingReportingOverflow(count)
                guard !over else { return false }

                runs[last].count = joined
                blocks           = total
                return true
            }
        }

        guard Int(extents) < FSLayout.extentLimit else { return false }

        runs[Int(extents)] = FSExtent(start: start, count: count)
        extents += 1
        blocks   = total

        return true
    }
}
