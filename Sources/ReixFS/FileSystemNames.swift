//
//  FileSystemNames.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// Names, and the folders that hold them.
///
/// A folder's contents are its bytes: a run of fixed-width entries, as many per
/// block as fit. Nothing is sorted and nothing is indexed, so a lookup is a
/// scan. On a disk this size that is a handful of blocks, and an index is a
/// thing to add when a measurement asks for it rather than because a bigger
/// system has one.
extension FileSystem {

    /// How many entries fit in one block.
    static var entriesPerBlock: UInt64 { FSLayout.blockSize / FSLayout.entrySize }


    /// The object a name refers to inside `folder`.
    ///
    /// `refused(.notFound)` is "there is no such name", and it is the only
    /// refusal that means that. A folder that would not read, a folder that is a
    /// file, and an entry the disk contradicts itself about are three other
    /// answers, and all four used to arrive as one `nil`.
    ///
    /// Which mattered most in `create`: "no such name" is what authorises writing
    /// one, so a directory block that would not read used to authorise a second
    /// entry with a name the folder already had.
    ///
    /// The entry says where the thing is, and the thing has to agree. A name is
    /// one folder's way of reaching something and `parent` is the thing's own
    /// account of which folder that is, so a name whose target names a different
    /// folder is not a name: it is a forgery or a wreck. This is what stops a
    /// made-up entry resolving outside the caller's reach - containment is a walk
    /// up the parent chain, and an entry planted in a folder somebody holds used
    /// to hand back an object that chain never passes through.
    public mutating func lookup(
        _  name  : UnsafeRawPointer,
           length: Int,
        in folder: UInt32
    ) -> FSFound {

        var found: UInt32? = nil

        let walked = forEachEntry(in: folder) { entry, _, _ in
            guard found == nil, entry.matches(name, length: length) else { return }
            found = entry.object
        }
        guard walked == .ok else { return .refused(walked) }

        guard let object = found else { return .refused(.notFound) }

        switch readObject(object) {
            case .live(let record):
                guard record.parent == folder else {
                    quarantine()
                    return .refused(.quarantined)
                }

            case .free, .outside:
                quarantine()
                return .refused(.quarantined)

            case .failed(let why):
                return .refused(why)

            case .corrupt:
                return .refused(.quarantined)
        }

        return .at(object)
    }


    /// Hands every live entry of `folder` to `body`, with the block and slot it
    /// sits in.
    ///
    /// The block number and slot come out because everything that changes a
    /// folder needs them, and finding an entry twice - once to see it, once to
    /// write it - is the kind of duplication that goes wrong quietly.
    ///
    /// A status, and no longer nothing at all. It used to `return` on an
    /// unreadable directory block and on a folder that was a file, which every
    /// caller read as "there are no entries" - and that is the answer `create`
    /// treats as permission to add one.
    @discardableResult
    mutating func forEachEntry(
        in folder: UInt32,
        _  body  : (FSEntry, UInt32, Int) -> Void
    ) -> FSStatus {

        guard let record = object(folder) else { return explain(.notFound) }
        guard record.standing == .live else { return .notFound }
        guard record.kind != .file else { return .wrongKind }

        let perBlock = Int(Self.entriesPerBlock)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                let loaded = readBlock(block, into: dataBuffer)
                guard loaded == .ok else { return loaded }

                for slot in 0..<perBlock {
                    let entry = FSEntry(
                        reading: dataBuffer.advanced(by: slot * Int(FSLayout.entrySize))
                    )

                    switch entry.standing {
                        case .free: continue

                        // Refused so that the clamp on the length cannot pass
                        // for an unused slot. See `FSEntry.standing`.
                        case .impossible:
                            quarantine()
                            return .quarantined

                        case .named: body(entry, block, slot)
                    }
                }
            }
        }

        return .ok
    }


    /// As many of `folder`'s names as fit, in one pass.
    ///
    /// The replacement for asking once per name. That cost a call and a read of
    /// the same directory block for every entry, and the read was not the worst
    /// of it: `entry(from:in:)` walks from the start of the folder to the cursor
    /// every time, so a folder of *n* names was walked *n* times and the listing
    /// grew with the square of the folder. This walks once.
    ///
    /// Each block is read once and every live entry inside it is taken before the
    /// next block is touched, which is what makes ten names two reads rather than
    /// ten. It stops on the first of three things: the destination is full, the
    /// folder ends, or the disk stops answering - and the three are told apart in
    /// what comes back rather than all being "nothing".
    ///
    /// The `reference` of each entry is the raw object index. Turning it into a
    /// handle needs the object's generation, which is a record read and not this
    /// walk's business: see `FSListEntry.reference`.
    ///
    /// Every target is read and asked whether it agrees. The kind used to be
    /// `object(entry.object)?.kind ?? .free`, which invented a fact: a folder
    /// whose entry named a slot nobody uses came back with a free-kinded name in
    /// the listing, and a name pointing into another folder came back at all.
    /// Both are the disk contradicting itself, so the batch carries a refusal
    /// instead of an entry, with whatever was found before it attached.
    public mutating func entries(
        from cursor: UInt32,
        in   folder: UInt32,
        into destination: UnsafeMutableRawPointer,
        capacity   : Int
    ) -> FSListBatchResult {

        guard capacity > 0 else {
            return FSListBatchResult(status: .ok, count: 0, next: cursor, eof: false)
        }

        // A slot nobody uses is not an empty folder. Answering "no entries, and
        // that is the end of them" would turn a name for something gone into a
        // valid listing of nothing.
        guard let record = object(folder), record.standing == .live else {
            return FSListBatchResult(status: explain(.notFound), count: 0, next: cursor, eof: false)
        }

        guard record.kind != .file else {
            return FSListBatchResult(status: .wrongKind, count: 0, next: cursor, eof: false)
        }

        let perBlock = UInt32(Self.entriesPerBlock)

        var position = UInt32(0)
        var written  = 0
        var resume   = cursor

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {

                // Whole blocks before the cursor are skipped without reading
                // them, which is the point of counting in slots.
                if position + perBlock <= resume {
                    position += perBlock
                    continue
                }

                let loaded = readBlock(block, into: dataBuffer)
                guard loaded == .ok else {
                    // Whatever was found before this stays found. A partial
                    // answer with a failure on it is more use than throwing away
                    // the names that did read.
                    return FSListBatchResult(
                        status: loaded, count: written, next: resume, eof: false
                    )
                }

                for slot in 0..<perBlock {
                    let here = position + slot
                    guard here >= resume else { continue }

                    let entry = FSEntry(
                        reading: dataBuffer.advanced(by: Int(slot) * Int(FSLayout.entrySize))
                    )

                    switch entry.standing {
                        case .free: continue

                        case .impossible:
                            quarantine()
                            return FSListBatchResult(
                                status: .quarantined, count: written, next: resume, eof: false
                            )

                        case .named: break
                    }

                    guard written < capacity else {
                        // Full, and not the end: `resume` is this entry, so the
                        // next batch begins with the one that did not fit.
                        return FSListBatchResult(
                            status: .ok, count: written, next: here, eof: false
                        )
                    }

                    switch readObject(entry.object) {
                        case .live(let target):
                            guard target.parent == folder else {
                                quarantine()
                                return FSListBatchResult(
                                    status: .quarantined, count: written, next: resume, eof: false
                                )
                            }

                            FSListEntry(
                                reference: entry.object,
                                kind     : target.kind,
                                length   : entry.length,
                                name     : entry.name
                            ).write(to: destination.advanced(by: written * FSListEntry.width))

                        case .free, .outside, .corrupt:
                            quarantine()
                            return FSListBatchResult(
                                status: .quarantined, count: written, next: resume, eof: false
                            )

                        case .failed(let why):
                            return FSListBatchResult(
                                status: why, count: written, next: resume, eof: false
                            )
                    }

                    written += 1
                    resume   = here + 1
                }

                position += perBlock
            }
        }

        // Every block walked and nothing left: the folder ends here, whether or
        // not this batch had room to spare.
        return FSListBatchResult(status: .ok, count: written, next: resume, eof: true)
    }


    /// Whether `folder` holds anything at all: `ok` when it does not.
    ///
    /// A status and not a `Bool`, because the answer authorises a removal. A
    /// folder whose directory block would not read answered "empty", and `remove`
    /// read that as permission to free a folder with things still in it.
    public mutating func emptiness(of folder: UInt32) -> FSStatus {

        var empty = true

        let walked = forEachEntry(in: folder) { _, _, _ in empty = false }
        guard walked == .ok else { return walked }

        return empty ? .ok : .notEmpty
    }


    /// Writes `entry` into `folder`, growing it by a block when every slot is
    /// taken.
    mutating func link(
        _  entry : FSEntry,
        in folder: UInt32
    ) -> FSStatus {

        guard let held = object(folder) else { return explain(.notFound) }
        guard held.standing == .live, held.kind != .file else { return .wrongKind }

        var record   = held
        let perBlock = Int(Self.entriesPerBlock)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                let loaded = readBlock(block, into: dataBuffer)
                guard loaded == .ok else { return loaded }

                for slot in 0..<perBlock {
                    let at = slot * Int(FSLayout.entrySize)

                    switch FSEntry(reading: dataBuffer.advanced(by: at)).standing {
                        case .named: continue

                        // Not a slot to write into. The clamp made a corrupt entry
                        // look unused, so a name used to be laid over one.
                        case .impossible:
                            quarantine()
                            return .quarantined

                        case .free: break
                    }

                    entry.write(to: dataBuffer.advanced(by: at))
                    return stageStructuralBlock(block, from: dataBuffer)
                }
            }
        }

        // Full. One more block, zeroed, and the entry goes at the front of it.
        // Charged first: a container out of room cannot grow a folder either.
        let booked = charge(1, to: folder)
        guard booked == .ok else { return booked }

        let room = allocateRun(1)
        guard case .taken(let fresh, _) = room else { return room.refusal }

        // Re-read: charging rewrites the container's record, and when the folder
        // *is* that container the copy taken above is now stale.
        guard let reread = object(folder) else { return explain(.notFound) }
        record = reread

        guard record.append(start: fresh, count: 1) else { return .tooFragmented }

        dataBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        entry.write(to: dataBuffer)

        let staged = stageStructuralBlock(fresh, from: dataBuffer)
        guard staged == .ok else { return staged }

        record.size     = UInt64(record.blocks) * FSLayout.blockSize
        record.modified = now

        return store(record, at: folder)
    }


    /// Clears the entry naming `name` in `folder`, leaving the object alone.
    mutating func unlink(
        _    name  : UnsafeRawPointer,
             length: Int,
        from folder: UInt32
    ) -> FSStatus {

        var target: (block: UInt32, slot: Int)? = nil

        let walked = forEachEntry(in: folder) { entry, block, slot in
            guard target == nil, entry.matches(name, length: length) else { return }
            target = (block, slot)
        }
        guard walked == .ok else { return walked }

        guard let target else { return .notFound }

        let loaded = readBlock(target.block, into: dataBuffer)
        guard loaded == .ok else { return loaded }

        FSEntry().write(to: dataBuffer.advanced(by: target.slot * Int(FSLayout.entrySize)))

        return stageStructuralBlock(target.block, from: dataBuffer)
    }


    // MARK: - What callers actually ask for

    /// Makes a new object of `kind` and names it in `folder`.
    public mutating func create(
        _  name  : UnsafeRawPointer,
           length: Int,
           kind  : FSKind,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {

        guard kind != .container else { return (.wrongKind, 0) }

        // The record and the name it is reached by, in one transaction. Two
        // writes and no order between them that helps: a crash after the record
        // is a live object nothing names, a crash after the entry is a name
        // pointing at a free slot. Neither is a state anything can classify.
        let begun = begin()
        guard begun == .ok else { return (begun, 0) }

        let made  = createStaged(name, length: length, kind: kind, in: folder)
        let ended = finish(made.status)

        return (ended, ended == .ok ? made.object : 0)
    }


    mutating func createStaged(
        _  name  : UnsafeRawPointer,
           length: Int,
           kind  : FSKind,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {

        guard kind != .free else { return (.wrongKind, 0) }

        guard let parent = object(folder) else { return (explain(.notFound), 0) }
        guard parent.standing == .live, parent.kind != .file else {
            return (.wrongKind, 0)
        }

        // Enforced where the depth grows. See `FSStatus.tooDeep`.
        guard let deep = depth(of: folder) else { return (explain(.notFound), 0) }
        guard deep + 1 < Self.nestingLimit else { return (.tooDeep, 0) }

        // Only `notFound` is permission to write this name. An unreadable folder
        // used to be permission too.
        let taken = lookup(name, length: length, in: folder)
        guard taken.refusal == .notFound else {
            return (taken.refusal == .ok ? .exists : taken.refusal, 0)
        }

        guard let entry = FSEntry(object: 0, name: name, length: length) else {
            return (.badName, 0)
        }

        let slot = allocateObject(kind: kind)
        guard case .at(let index) = slot else { return (slot.refusal, 0) }

        // Charged to the container it was made in and sitting in the folder it
        // was made in, from the moment it exists. Refused, never skipped.
        guard var fresh = object(index), let place = charged(folder) else {
            return (explain(.notFound), 0)
        }

        fresh.container = place
        fresh.parent    = folder

        let placed = store(fresh, at: index)
        guard placed == .ok else { return (placed, 0) }

        var named = entry
        named.object = index

        // No undoing by hand. The transaction around this is the undo: a failure
        // here abandons every staged image, so the slot this took is a slot
        // nothing on the disk was ever told about.
        let status = link(named, in: folder)
        guard status == .ok else { return (status, 0) }

        return (.ok, index)
    }


    /// Unnames an object and, since nothing else can be holding it, takes its
    /// blocks back.
    ///
    /// One name per object is the rule this format keeps: there are no hard
    /// links, so removing the name is removing the thing. A folder with
    /// anything in it is refused rather than emptied, because deleting a tree
    /// on somebody's behalf is a decision, not an operation.
    ///
    /// A container's room goes back to the container that lent it, and both
    /// halves of that are refusals now: a parent that is not a container cannot
    /// be true of a disk this wrote, and a sum of two numbers read off a disk is
    /// a sum that can trap.
    public mutating func remove(
        _    name  : UnsafeRawPointer,
             length: Int,
        from folder: UInt32
    ) -> FSStatus {

        // The entry, the freed record, the bitmap and the container's room, in one
        // transaction. The old write order made the residue a leak on purpose;
        // now there is no residue.
        let begun = begin()
        guard begun == .ok else { return begun }

        let removed = removeStaged(name, length: length, from: folder)
        let ended = finish(removed.status)

        if ended == .ok, removed.container {
            if let count = containerCount, count > 0 {
                containerCount = count - 1
            } else {
                containerCount = nil
            }
        } else if removed.status == .ok {
            containerCount = nil
        }

        return ended
    }


    mutating func removeStaged(
        _    name  : UnsafeRawPointer,
             length: Int,
        from folder: UInt32
    ) -> (status: FSStatus, container: Bool) {

        let found = lookup(name, length: length, in: folder)
        guard case .at(let index) = found else { return (found.refusal, false) }

        guard index != FSLayout.rootObject else { return (.wrongKind, false) }

        guard let target = object(index) else { return (explain(.notFound), false) }

        // Only `ok` is permission to remove a folder. A folder that would not read
        // answered "empty", and this read that as permission.
        if target.kind != .file {
            let empty = emptiness(of: index)
            guard empty == .ok else { return (empty, false) }
        }

        // Unnamed, unroomed, unrecorded, in that order and with nothing between
        // them. The order used to be load-bearing and argued for at length - a
        // crash between the unlink and the release left a leak, the other way
        // round left a name resolving to somebody else's file - and the barrier
        // in the middle was what made the argument true of the medium. There is
        // no "in between" left: all three are staged into one transaction.
        let status = unlink(name, length: length, from: folder)
        guard status == .ok else { return (status, false) }

        // A container's room goes back to the one that gave it. Space is
        // delegated, and a delegation that ends returns what it was lent.
        if target.kind == .container, target.quota > 0, target.container != index {
            guard var parent = object(target.container),
                      parent.kind == .container else { return (explain(.notFound), false) }

            let (whole, over) = parent.quota.addingReportingOverflow(target.quota)
            guard !over else { return (.noSpace, false) }

            parent.quota = whole

            let returned = store(parent, at: target.container)
            guard returned == .ok else { return (returned, false) }
        }

        return (releaseObject(index), target.kind == .container)
    }
}
