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
/// transaction: prepared, committed, and empty. Four for a write that lands on
/// blocks a file already has, which names them and their new checksums in a
/// `prepared` header first. It is the only thing on the disk whose state has to
/// be believed without anything else to check it against, so every field of it
/// is covered by a checksum and each payload carries one of its own.
///
/// The empty mark carries the **checkpoint**: the generation of the newest
/// transaction the home blocks hold. One write for both, because they are one
/// fact - the journal is empty *because* everything up to there has been applied.
/// See `stamp`.
///
/// A **redo** journal, of metadata. What goes in it is the after-image of whole
/// structural blocks: a bitmap block, an object table block, a sum block, a
/// directory block. Whole images rather than deltas is what makes replay
/// idempotent, which is what makes a crash during replay survivable - replaying
/// twice is replaying once. File contents are not in here, with one exception:
/// the partly filled last block an append rewrites goes through as an image, so
/// a log never loses its last block to a power cut. Everything else a write
/// lands on is named first. See `Intent`.
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

        /// How many runs of file data the transaction overwrites in place, then
        /// eight `{ start, count }` pairs. See `Intent`.
        static let intentCount = records + FSJournal.capacity * recordWidth
        static let intentRuns  = intentCount + 4

        /// The checksum over the declared checksums below.
        static let declaredCheck = intentRuns + FSJournal.Intent.limit * 8

        /// Inside the first sector, so a write the device tears cannot tear it.
        static var width: Int { declaredCheck + 4 }

        /// The new checksum of every block the intent names, in the order it
        /// names them, from the second sector to the end of the block.
        ///
        /// Outside the first sector, so a torn header can carry a whole state
        /// and half of these. `declaredCheck` says so, and the blocks they
        /// describe cannot have been written yet: nothing is, until the header
        /// that names them is durable. Every header written while an intent is
        /// open carries the same bytes here, so a tear between two of them is
        /// still whole.
        static let declared = 512
    }


    /// The blocks of file data a transaction overwrites in place, named on the
    /// disk before the first of them is written.
    ///
    /// File data is not journalled, so an overwrite reaches its home block
    /// before the commit that carries its new checksum, and a power cut in
    /// between leaves new bytes under an old checksum. These are the only blocks
    /// that can be in that state. A `prepared` header carrying them is settled
    /// before it is cleared: a block that holds what its old checksum or its
    /// declared new one describes is kept as that, and anything else, rot or a
    /// block torn between the two, keeps the old checksum and reads as damaged.
    ///
    /// Runs, at most eight: one write touches one file, and a file has eight.
    struct Intent {

        static let limit = FSLayout.extentLimit

        var runs  = InlineArray<8, FSExtent>(repeating: FSExtent())
        var count = 0

        var isEmpty: Bool { count == 0 }

        /// Adds one block, onto the last run when it carries straight on from it.
        mutating func add(_ block: UInt32) -> Bool {
            if count > 0 {
                let last = runs[count - 1]
                if UInt64(last.start) + UInt64(last.count) == UInt64(block) {
                    runs[count - 1].count = last.count + 1
                    return true
                }
            }

            guard count < Self.limit else { return false }

            runs[count] = FSExtent(start: block, count: 1)
            count += 1
            return true
        }

        /// How many blocks the runs name. Only meaningful once `fits` holds.
        var blocks: Int {
            var total = 0
            for index in 0..<count { total += Int(runs[index].count) }
            return total
        }

        /// Whether every run is file data on this disk, and the whole of it
        /// within `FSLayout.overwriteLimit`. A settle reads every block named.
        func fits(_ plan: FSLayout.Plan) -> Bool {
            var total = UInt64(0)

            for index in 0..<count {
                let run = runs[index]
                let end = UInt64(run.start) + UInt64(run.count)

                guard run.count > 0, run.start >= plan.dataStart,
                      end <= UInt64(plan.totalBlocks)
                else { return false }

                total += UInt64(run.count)
            }

            return total <= FSLayout.overwriteLimit
        }
    }


    var state      : State
    var generation : UInt64
    var recordCount: Int

    var targets  : InlineArray<16, UInt32>
    var checksums: InlineArray<16, UInt32>

    var intent: Intent


    /// An empty journal, which is what `format` lays down and what every
    /// finished transaction leaves behind.
    init() {
        self.state       = .empty
        self.generation  = 0
        self.recordCount = 0
        self.targets     = InlineArray<16, UInt32>(repeating: 0)
        self.checksums   = InlineArray<16, UInt32>(repeating: 0)
        self.intent      = Intent()
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

        var intent = Intent()
        let named  = base.loadUnaligned(fromByteOffset: Header.intentCount, as: UInt32.self)
        intent.count = Int(named) <= Intent.limit ? Int(named) : Intent.limit

        for index in 0..<Intent.limit {
            let at = Header.intentRuns + index * 8
            intent.runs[index] = FSExtent(
                start: base.loadUnaligned(fromByteOffset: at,     as: UInt32.self),
                count: base.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self)
            )
        }
        self.intent = intent
    }


    /// Lays the header over a whole block, checksum last.
    ///
    /// `declared` holds the new checksum of every block the intent names, four
    /// bytes each in the intent's order. Without it the declared checksums are
    /// left out and `declares` says so.
    func write(to base: UnsafeMutableRawPointer, declaring declared: UnsafeRawPointer? = nil) {

        base.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        let width = intent.blocks * 4
        if let declared, width > 0 {
            base.advanced(by: Header.declared).copyMemory(from: declared, byteCount: width)
        }

        let check = FSChecksum.over(base.advanced(by: Header.declared), count: width)
        base.storeBytes(
            of: declared == nil ? ~check : check, toByteOffset: Header.declaredCheck, as: UInt32.self
        )

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

        base.storeBytes(of: UInt32(intent.count), toByteOffset: Header.intentCount, as: UInt32.self)

        for index in 0..<Intent.limit {
            let at = Header.intentRuns + index * 8
            base.storeBytes(of: intent.runs[index].start, toByteOffset: at,     as: UInt32.self)
            base.storeBytes(of: intent.runs[index].count, toByteOffset: at + 4, as: UInt32.self)
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
                <= UInt32(capacity),
              base.loadUnaligned(fromByteOffset: Header.intentCount, as: UInt32.self)
                <= UInt32(Intent.limit)
        else { return false }

        let stored = base.loadUnaligned(fromByteOffset: Header.checksum, as: UInt32.self)

        return stored == FSChecksum.over(base, count: Header.width, zeroing: Header.checksum)
    }


    /// Whether `base`, a header whose intent fits this disk, holds the new
    /// checksum of every block that intent names.
    ///
    /// False for a declaration torn on its way to the medium, and for one
    /// written without them. Either way no named block has been written yet.
    func declares(_ base: UnsafeRawPointer) -> Bool {
        base.loadUnaligned(fromByteOffset: Header.declaredCheck, as: UInt32.self)
            == FSChecksum.over(base.advanced(by: Header.declared), count: intent.blocks * 4)
    }


    /// Whether every record names a block this journal may write over, and the
    /// intent names only file data.
    ///
    /// The journal's own blocks and the superblocks are not among them: a record
    /// pointing at the header would have replay rewrite the thing that says what
    /// to replay, and one pointing at a superblock would put a metadata image
    /// where the layout lives.
    func targetsFit(_ plan: FSLayout.Plan) -> Bool {

        guard intent.fits(plan) else { return false }

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
