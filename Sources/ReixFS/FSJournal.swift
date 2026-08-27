//
//  FSJournal.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import ReixABI

/// What the journal is holding, as it says so on the disk.
///
/// One block, at a fixed address, read once at mount and written three times per
/// transaction: prepared, committed, and empty. It is the only thing on the disk
/// whose state has to be believed without anything else to check it against, so
/// every field of it is covered by a checksum and each payload carries one of its
/// own.
///
/// The empty mark carries the **checkpoint**: the generation of the newest
/// transaction the home blocks hold. One write for both, because they are one
/// fact - the journal is empty *because* everything up to there has been applied.
/// See `stamp`.
///
/// A **redo** journal, and metadata only. What goes in it is the after-image of
/// whole structural blocks: a bitmap block, an object table block, a directory
/// block. Whole images rather than deltas is what makes replay idempotent, which
/// is what makes a crash during replay survivable - replaying twice is replaying
/// once. File contents are not in here and are not meant to be: what a
/// transaction promises is that the metadata is coherent, not that a power cut
/// cannot land in the middle of somebody's bytes.
///
/// The payload blocks are written **once each, at the commit**. Staging keeps the
/// image in an arena in memory and overwrites it in place, so a transaction that
/// changes one bitmap block four times pays for one payload write rather than
/// four. See `FileSystem.stageStructuralBlock`.
struct FSJournal {

    /// `RXJRNL` and a version, so a hex dump of block two says what it is.
    static let magic: UInt64 = 0x3130_4C4E_524A_5852      // "RXJRNL01"

    static let version: UInt32 = 1

    /// How many after-images one transaction may hold. The payload blocks are
    /// laid down consecutively from `FSLayout.journalStart`.
    static let capacity = Int(FSLayout.journalBlocks)


    /// Where the journal is in its own protocol.
    ///
    /// Three states and the order they go in is the whole guarantee. `prepared`
    /// means the after-images are on the medium and the transaction is *not*
    /// promised; `committed` means it is, and every image will be applied however
    /// many times the machine restarts before it finishes.
    enum State: UInt32, Equatable {

        /// Nothing outstanding. The only state a transaction may begin from.
        case empty = 0

        /// The images are written and the transaction is not promised. A mount
        /// that finds this throws them away: nothing on the disk depends on them.
        case prepared = 1

        /// The transaction exists. A mount that finds this applies every image,
        /// whether or not it was applied before the power went.
        case committed = 2
    }


    /// Where each field of the header block lives.
    enum Header {
        static let magic       = 0
        static let version     = 8
        static let state       = 12
        static let generation  = 16
        static let recordCount = 24
        static let checksum    = 28

        /// Sixteen pairs of `{ target block, payload checksum }`.
        static let records     = 32
        static let recordWidth = 8

        static var width: Int { records + FSJournal.capacity * recordWidth }
    }


    var state      : State
    var generation : UInt64
    var recordCount: Int

    var targets  : InlineArray<16, UInt32>
    var checksums: InlineArray<16, UInt32>


    /// An empty journal, which is what `format` lays down and what every
    /// finished transaction leaves behind.
    init() {
        self.state       = .empty
        self.generation  = 0
        self.recordCount = 0
        self.targets     = InlineArray<16, UInt32>(repeating: 0)
        self.checksums   = InlineArray<16, UInt32>(repeating: 0)
    }


    /// The fields as they stand in `base`. No judgement; see `verdict`.
    init(reading base: UnsafeRawPointer) {
        self.state = State(
            rawValue: base.loadUnaligned(fromByteOffset: Header.state, as: UInt32.self)
        ) ?? .empty

        self.generation = base.loadUnaligned(
            fromByteOffset: Header.generation, as: UInt64.self
        )

        let raw = base.loadUnaligned(fromByteOffset: Header.recordCount, as: UInt32.self)
        self.recordCount = Int(raw) <= Self.capacity ? Int(raw) : Self.capacity

        var targets   = InlineArray<16, UInt32>(repeating: 0)
        var checksums = InlineArray<16, UInt32>(repeating: 0)

        for index in 0..<Self.capacity {
            let at = Header.records + index * Header.recordWidth
            targets[index]   = base.loadUnaligned(fromByteOffset: at,     as: UInt32.self)
            checksums[index] = base.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)
        }

        self.targets   = targets
        self.checksums = checksums
    }


    /// Lays the header over a whole block, checksum last.
    func write(to base: UnsafeMutableRawPointer) {

        base.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        base.storeBytes(of: Self.magic,          toByteOffset: Header.magic,      as: UInt64.self)
        base.storeBytes(of: Self.version,        toByteOffset: Header.version,    as: UInt32.self)
        base.storeBytes(of: state.rawValue,      toByteOffset: Header.state,      as: UInt32.self)
        base.storeBytes(of: generation,          toByteOffset: Header.generation, as: UInt64.self)
        base.storeBytes(of: UInt32(recordCount), toByteOffset: Header.recordCount, as: UInt32.self)

        for index in 0..<Self.capacity {
            let at = Header.records + index * Header.recordWidth
            base.storeBytes(of: targets[index],   toByteOffset: at,     as: UInt32.self)
            base.storeBytes(of: checksums[index], toByteOffset: at + 4, as: UInt32.self)
        }

        base.storeBytes(
            of          : FSChecksum.over(base, count: Header.width, zeroing: Header.checksum),
            toByteOffset: Header.checksum,
            as          : UInt32.self
        )
    }


    /// Whether a header block is one this build wrote and can act on.
    static func isWhole(_ base: UnsafeRawPointer) -> Bool {

        guard base.loadUnaligned(fromByteOffset: Header.magic, as: UInt64.self) == magic,
              base.loadUnaligned(fromByteOffset: Header.version, as: UInt32.self) == version
        else { return false }

        // A state this build does not know is not a state to act on: replaying a
        // journal whose protocol has changed is worse than refusing it.
        guard let raw = State(
            rawValue: base.loadUnaligned(fromByteOffset: Header.state, as: UInt32.self)
        ) else { return false }
        _ = raw

        guard base.loadUnaligned(fromByteOffset: Header.recordCount, as: UInt32.self)
                <= UInt32(capacity)
        else { return false }

        let stored = base.loadUnaligned(fromByteOffset: Header.checksum, as: UInt32.self)

        return stored == FSChecksum.over(base, count: Header.width, zeroing: Header.checksum)
    }


    /// Whether every record names a block this journal may write over.
    ///
    /// The journal's own blocks and the superblocks are not among them: a record
    /// pointing at the header would have replay rewrite the thing that says what
    /// to replay, and one pointing at a superblock would put a metadata image
    /// where the layout lives.
    func targetsFit(_ plan: FSLayout.Plan) -> Bool {

        for index in 0..<recordCount {
            let target = targets[index]

            guard target >= FSLayout.reservedBlocks,
                  target < plan.totalBlocks
            else { return false }
        }

        return true
    }


    /// Which payload block holds record `index`.
    static func payload(of index: Int) -> UInt32 {
        FSLayout.journalStart + UInt32(index)
    }


    // MARK: - Which mount wrote this

    /// A generation, as the mount that wrote it and the step within that mount.
    ///
    /// **The two halves are the checkpoint.** The high word is the superblock
    /// generation the volume was serving under, which every mount bumps and which
    /// is durable in two copies; the low word counts transactions inside that
    /// mount. So a journal says not only "the fourth transaction" but "the fourth
    /// transaction *of that mount*", and a mount can tell a journal it is meant to
    /// finish from one that was finished before it started.
    ///
    /// Which is the whole point. The step alone restarted at zero every mount, so
    /// a crash could leave a committed journal numbered below one that had already
    /// been applied, and nothing on the disk said which of the two the home blocks
    /// held. A whole-block after-image applied over newer metadata is silent.
    ///
    /// Still one packed sixty-four-bit stamp in the field it always was, so no
    /// disk written by an older build has to be read differently: its small
    /// generations read as mount zero, which no live mount ever is. It is not an
    /// anti-rollback counter; it only rejects a committed earlier-mount journal
    /// while a newer superblock is present on this medium.
    /// `nil` above the bound: the mount half is a word, so a volume opened four
    /// thousand million times has run out of stamps rather than started reusing
    /// them. Unreachable, and a refusal for the same reason `publishSuperblock`
    /// refuses at the top of its own counter: a stamp handed out twice is a
    /// journal a replay cannot place.
    static func stamp(mount: UInt64, step: UInt32) -> UInt64? {
        guard mount <= UInt64(UInt32.max) else { return nil }

        return (mount << 32) | UInt64(step)
    }

    /// The superblock generation the mount that wrote this was serving under.
    static func mount(of generation: UInt64) -> UInt64 {
        generation >> 32
    }

    /// Which transaction of that mount this was.
    static func step(of generation: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: generation)
    }
}
