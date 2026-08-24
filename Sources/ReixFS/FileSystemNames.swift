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
    public mutating func lookup(
        _  name  : UnsafeRawPointer,
           length: Int,
        in folder: UInt32
    ) -> UInt32? {

        var found: UInt32? = nil

        forEachEntry(in: folder) { entry, _, _ in
            guard found == nil, entry.matches(name, length: length) else { return }
            found = entry.object
        }

        guard let object = found else { return nil }

        // The entry says where the thing is; the thing has to agree. A name is
        // one folder's way of reaching something, and `parent` is the thing's own
        // account of which folder that is - so a name whose target names a
        // different folder is not a name, it is a forgery or a wreck.
        //
        // This is what stops a made-up entry from resolving outside the caller's
        // reach. Containment is a walk up the parent chain, so an entry planted
        // in a folder somebody holds used to hand back an object that chain
        // never passes through.
        guard object < plan.objectCount,
              let record = self.object(object),
              record.kind != .free,
              record.parent == folder
        else { return nil }

        return object
    }


    /// Hands every live entry of `folder` to `body`, with the block and slot it
    /// sits in.
    ///
    /// The block number and slot come out because everything that changes a
    /// folder needs them, and finding an entry twice - once to see it, once to
    /// write it - is the kind of duplication that goes wrong quietly.
    mutating func forEachEntry(
        in folder: UInt32,
        _  body  : (FSEntry, UInt32, Int) -> Void
    ) {
        guard let record = object(folder), record.kind != .file else { return }

        let perBlock = Int(Self.entriesPerBlock)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                guard readBlock(block, into: dataBuffer) == .ok else { return }

                for slot in 0..<perBlock {
                    let entry = FSEntry(
                        reading: dataBuffer.advanced(by: slot * Int(FSLayout.entrySize))
                    )
                    guard !entry.isFree else { continue }

                    body(entry, block, slot)
                }
            }
        }
    }


    /// The next live entry of `folder` at or after `cursor`, and where to
    /// resume.
    ///
    /// A cursor and not an index. An index meant restarting the scan for every
    /// name, so listing a folder of *n* entries read the folder *n* times: the
    /// listing cost grew with the square of the folder. The cursor is a slot
    /// number the caller hands back, so a full listing is one pass however long
    /// it is.
    ///
    /// It is a position and not a promise. Nothing stops the folder changing
    /// between two calls, and a cursor into a folder that changed lands
    /// wherever that slot now is, which is the same guarantee a directory read
    /// has anywhere: you see a folder, not a moment.
    public mutating func entry(
        from cursor: UInt32,
        in   folder: UInt32
    ) -> (entry: FSEntry, next: UInt32)? {

        guard let record = object(folder), record.kind != .file else { return nil }

        let perBlock = UInt32(Self.entriesPerBlock)
        var position = UInt32(0)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {

                // Whole blocks before the cursor are skipped without reading
                // them, which is the point of counting in slots.
                if position + perBlock <= cursor {
                    position += perBlock
                    continue
                }

                guard readBlock(block, into: dataBuffer) == .ok else { return nil }

                for slot in 0..<perBlock {
                    let here = position + slot
                    guard here >= cursor else { continue }

                    let entry = FSEntry(
                        reading: dataBuffer.advanced(by: Int(slot) * Int(FSLayout.entrySize))
                    )
                    guard !entry.isFree else { continue }

                    return (entry, here + 1)
                }

                position += perBlock
            }
        }

        return nil
    }


    /// Whether `folder` holds anything at all.
    public mutating func isEmpty(_ folder: UInt32) -> Bool {

        var empty = true
        forEachEntry(in: folder) { _, _, _ in empty = false }

        return empty
    }


    /// Writes `entry` into `folder`, growing it by a block when every slot is
    /// taken.
    mutating func link(
        _  entry : FSEntry,
        in folder: UInt32
    ) -> FSStatus {

        guard var record = object(folder), record.kind != .file else { return .wrongKind }

        let perBlock = Int(Self.entriesPerBlock)

        for run in 0..<Int(record.extents) {
            let extent = record.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                guard readBlock(block, into: dataBuffer) == .ok else { return .deviceFailed }

                for slot in 0..<perBlock {
                    let at = slot * Int(FSLayout.entrySize)
                    guard FSEntry(reading: dataBuffer.advanced(by: at)).isFree else { continue }

                    entry.write(to: dataBuffer.advanced(by: at))
                    return writeBlock(block, from: dataBuffer)
                }
            }
        }

        // Full. One more block, zeroed, and the entry goes at the front of it.
        // Charged first: a container out of room cannot grow a folder either.
        let booked = charge(1, to: folder)
        guard booked == .ok else { return booked }

        guard let fresh = allocateRun(1) else {
            refund(1, to: folder)
            return explain(.noSpace)
        }

        // Re-read: charging rewrites the container's record, and when the folder
        // *is* that container the copy taken above is now stale.
        guard let reread = object(folder) else {
            releaseRun(start: fresh, count: 1)
            refund(1, to: folder)
            return explain(.notFound)
        }
        record = reread

        guard record.append(start: fresh, count: 1) else {
            releaseRun(start: fresh, count: 1)
            refund(1, to: folder)
            return .tooFragmented
        }

        dataBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        entry.write(to: dataBuffer)

        guard writeBlock(fresh, from: dataBuffer) == .ok else {
            releaseRun(start: fresh, count: 1)
            refund(1, to: folder)
            return .deviceFailed
        }

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

        forEachEntry(in: folder) { entry, block, slot in
            guard target == nil, entry.matches(name, length: length) else { return }
            target = (block, slot)
        }

        guard let target else { return .notFound }

        guard readBlock(target.block, into: dataBuffer) == .ok else { return .deviceFailed }

        FSEntry().write(to: dataBuffer.advanced(by: target.slot * Int(FSLayout.entrySize)))

        return writeBlock(target.block, from: dataBuffer)
    }


    // MARK: - What callers actually ask for

    /// Makes a new object of `kind` and names it in `folder`.
    public mutating func create(
        _  name  : UnsafeRawPointer,
           length: Int,
           kind  : FSKind,
        in folder: UInt32
    ) -> (status: FSStatus, object: UInt32) {

        guard kind != .free else { return (.wrongKind, 0) }

        guard let parent = object(folder), parent.kind != .file else {
            return (.wrongKind, 0)
        }

        guard lookup(name, length: length, in: folder) == nil else { return (.exists, 0) }

        guard let entry = FSEntry(object: 0, name: name, length: length) else {
            return (.badName, 0)
        }

        guard let index = allocateObject(kind: kind) else { return (explain(.noSpace), 0) }

        // Charged to the container it was made in and sitting in the folder it
        // was made in, from the moment it exists.
        if var fresh = object(index), let place = charged(folder) {
            fresh.container = place
            fresh.parent    = folder
            _ = store(fresh, at: index)
        }

        var named = entry
        named.object = index

        let status = link(named, in: folder)

        guard status == .ok else {
            _ = releaseObject(index)
            return (status, 0)
        }

        return (.ok, index)
    }


    /// Unnames an object and, since nothing else can be holding it, takes its
    /// blocks back.
    ///
    /// One name per object is the rule this format keeps: there are no hard
    /// links, so removing the name is removing the thing. A folder with
    /// anything in it is refused rather than emptied, because deleting a tree
    /// on somebody's behalf is a decision, not an operation.
    public mutating func remove(
        _    name  : UnsafeRawPointer,
             length: Int,
        from folder: UInt32
    ) -> FSStatus {

        guard let index = lookup(name, length: length, in: folder) else { return .notFound }
        guard index != FSLayout.rootObject else { return .wrongKind }

        guard let target = object(index) else { return .notFound }

        if target.kind != .file, !isEmpty(index) { return .notEmpty }

        // Unnamed first and released second, which is the opposite of the rule
        // on `barrier` and is right here for the same reason the rule is: a
        // crash in between leaves an object nothing names, whose blocks are
        // still marked used and still owned by it. That is a leak. Released
        // first would leave a *name* pointing at a slot the next `create` can
        // take, and a name that resolves to somebody else's file is worse than
        // any amount of lost space.
        let status = unlink(name, length: length, from: folder)
        guard status == .ok else { return status }

        guard barrier() == .ok else { return .deviceFailed }

        // A container's room goes back to the one that gave it. Space is
        // delegated, and a delegation that ends returns what it was lent.
        if target.kind == .container, target.quota > 0, target.container != index {
            if var parent = object(target.container), parent.kind == .container {
                parent.quota += target.quota
                _ = store(parent, at: target.container)
            }
        }

        return releaseObject(index)
    }
}
