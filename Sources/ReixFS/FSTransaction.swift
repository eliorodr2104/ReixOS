//
//  FSTransaction.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

import ReixABI

/// One transaction, while it is being built.
///
/// The in-memory half of the journal: which structural blocks this operation has
/// staged and which arena slot each one's after-image is in. `InlineArray`
/// throughout, because a file system server allocates nothing and this is on the
/// path of every change to the disk.
///
/// The images themselves are not here. They live in `FileSystem`'s arena, which
/// is sixty-four kilobytes of the caller's scratch: too much to copy every time
/// this struct is mutated, and the whole point of it is that staging is a copy
/// into memory rather than a write to the disk.
///
/// Two facts make it small. There is one writer, so there is one of these; and
/// the journal holds sixteen images, so the table is sixteen long and an
/// operation that would need a seventeenth is refused rather than committed in
/// halves.
struct FSTransaction {

    /// What a staging call may do when no transaction is open.
    ///
    /// `serving` refuses, and that refusal is the point of this type existing:
    /// a mutation that forgets to open a transaction cannot quietly go straight
    /// to the disk instead. The other two are the paths that write metadata with
    /// no journal because there is nothing yet to be coherent with - laying a
    /// fresh format down, and replaying one.
    enum Mode: Equatable {
        case serving
        case formatting
        case recovering
    }

    /// Where the same block staged twice goes.
    enum Slot: Equatable {

        /// This block already has an image in the arena. Overwrite that one.
        case again(Int)

        /// A slot nobody has used. The record count grows by one.
        case fresh(Int)

        /// Sixteen already. The operation is refused, and refused *before* the
        /// commit rather than truncated at it.
        case full
    }


    private(set) var active     = false
    private(set) var mode       = Mode.serving
    private(set) var generation = UInt64(0)
    private(set) var recordCount = 0

    /// The first refusal a staging call met inside this transaction.
    ///
    /// Sticky until the next `begin`, and it is what makes the whole of this
    /// fail-closed: a transaction whose staging was refused anywhere cannot be
    /// committed, whatever the operation on top of it believes it is handing to
    /// `finish`. Every mutation propagates its statuses now, and this is the
    /// backstop behind them - for the one that is missed, and for the mutation
    /// written next year by somebody who has not read this file.
    ///
    /// The *first* refusal and not the last, because the first is the one that
    /// explains the rest: a device that has stopped answering refuses everything
    /// after it, and the interesting fact is what it refused first.
    private(set) var stickyFailure: FSStatus? = nil

    private var targets   = InlineArray<16, UInt32>(repeating: 0)
    private var checksums = InlineArray<16, UInt32>(repeating: 0)

    /// How many operations were refused because sixteen images were not enough.
    ///
    /// It must stay at zero for the operations this format has. A number here is
    /// a real operation that cannot be made indivisible at this journal size,
    /// which is a fact about the design and not about the disk.
    private(set) var overflows: UInt32 = 0

    init() {}


    // MARK: - Opening and closing

    mutating func begin(generation: UInt64) {
        self.active        = true
        self.generation    = generation
        self.recordCount   = 0
        self.stickyFailure = nil
    }


    /// Records a refusal, so that this transaction can no longer be committed.
    ///
    /// A no-op outside a transaction: a fresh format and a replay have no
    /// transaction to poison, and neither has anything to stay coherent with.
    mutating func failed(_ status: FSStatus) {
        guard active, status != .ok, stickyFailure == nil else { return }

        stickyFailure = status
    }

    /// Closes the transaction, whether it was committed or abandoned.
    mutating func end() {
        active      = false
        recordCount = 0
    }


    /// Puts staging into a mode that writes home blocks directly.
    ///
    /// For `format` and for recovery, and for nothing else. Both are the only
    /// writer on the disk at the time and neither has a previous state to stay
    /// coherent with: a format is laying the metadata down in the first place,
    /// and a replay is *applying* a journal and must not journal what it applies.
    mutating func enter(_ mode: Mode) { self.mode = mode }

    mutating func serve() { mode = .serving }


    // MARK: - Staging

    /// Where the after-image of `target` goes.
    ///
    /// The same block staged twice takes the slot it already had, which is not
    /// only tidiness: it is what keeps a transaction that touches one bitmap block
    /// four times to one payload write and one home write. Write-coalescing and
    /// the sixteen-block bound are the same mechanism, and since the image lives
    /// in memory until the commit the fourth staging costs nothing at all.
    mutating func slot(for target: UInt32) -> Slot {

        for index in 0..<recordCount where targets[index] == target {
            return .again(index)
        }

        guard recordCount < FSJournal.capacity else { return .full }

        return .fresh(recordCount)
    }


    /// Whether the after-images of the blocks `first` through `last` would all
    /// fit in what is left of this transaction.
    ///
    /// The preflight, and it exists because the staging door sees one block at a
    /// time: by the moment it refuses the seventeenth, the first sixteen have
    /// already been written to the journal. A caller that can work out the whole
    /// set it is about to touch - a run of bitmap blocks is the one that can -
    /// asks here first and is refused whole.
    ///
    /// Blocks this transaction already has an image of are free, for the same
    /// reason `slot(for:)` reuses their slots: they cost no new record.
    func room(from first: UInt32, through last: UInt32) -> Bool {
        guard last >= first else { return true }

        var fresh  = 0
        var target = first

        // Counted up to and including `last`, without a `...` range: `last` may
        // be the largest block there is and the increment past it would trap.
        while true {
            if !holds(target) { fresh += 1 }

            if target == last { break }
            target += 1
        }

        return recordCount + fresh <= FSJournal.capacity
    }


    /// Whether this transaction already holds an image of `target`.
    private func holds(_ target: UInt32) -> Bool {
        for index in 0..<recordCount where targets[index] == target { return true }
        return false
    }


    /// Records that `target`'s image is in slot `index` and checksums to `sum`.
    mutating func staged(_ target: UInt32, at index: Int, checksum sum: UInt32) {
        guard index >= 0, index < FSJournal.capacity else { return }

        targets[index]   = target
        checksums[index] = sum

        if index >= recordCount { recordCount = index + 1 }
    }


    /// Counts an operation that asked for a seventeenth image.
    ///
    /// Saturating: it must stay at zero, so what matters is that it never reads
    /// as zero again once it is not. `&+=` would eventually say it did.
    mutating func overflowed() {
        if overflows < UInt32.max { overflows += 1 }
    }


    /// Which slot holds `target`'s staged image, if this transaction has one.
    ///
    /// What makes a read inside a transaction see the change: the home block
    /// still holds the old bytes, so a reader has to be sent to the journal
    /// instead. Without it an operation that stages a bitmap block and then reads
    /// it again would read what it had just replaced.
    func staging(_ target: UInt32) -> Int? {
        guard active else { return nil }

        for index in 0..<recordCount where targets[index] == target { return index }
        return nil
    }


    /// The header this transaction would write, in `state`.
    func header(_ state: FSJournal.State) -> FSJournal {
        var journal = FSJournal()

        journal.state       = state
        journal.generation  = generation
        journal.recordCount = recordCount

        for index in 0..<recordCount {
            journal.targets[index]   = targets[index]
            journal.checksums[index] = checksums[index]
        }

        return journal
    }
}
