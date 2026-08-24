//
//  FileSystem.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// A file system on any block device.
///
/// Generic over the device rather than over a disk, because `BlockDevice` is a
/// protocol and a slab of host memory conforms to it as readily as a virtio
/// queue does. That is what lets the whole of this be exercised without a disk,
/// a kernel, or a machine.
///
/// It allocates nothing. A few blocks of scratch memory arrive from the caller
/// and everything happens in them: one for metadata, one for file contents, and
/// `heldBlocks` more behind `readBlock`. The first two are separate because
/// almost every operation touches both, and a single buffer would mean
/// re-reading one of them after every switch.
public struct FileSystem<Device: BlockDevice> {

    /// How many of the file system's own blocks are held in hand.
    ///
    /// Two of them are hot: on a sixteen megabyte disk every object record this
    /// side of the first sixty-four lives in one table block, and there is one
    /// bitmap block, so a write touches those two over and over. Four leaves the
    /// superblock and a second table block somewhere to sit without evicting
    /// either.
    ///
    /// `InlineArray`'s length must be a literal, so the four in `tags` is the
    /// real bound and this is the name for it.
    static var heldBlocks: Int { 4 }

    /// A tag no block can wear, so an empty slot needs no second array.
    static var noBlock: UInt32 { .max }

    /// How much scratch memory to hand `init`. Contiguous, and all of it used.
    public static var scratchBytes: Int {
        Int(FSLayout.blockSize) * (2 + heldBlocks)
    }

    public var device: Device

    /// Metadata: the superblock, the bitmap, the object table.
    private let meta: UnsafeMutableRawPointer

    /// File contents and directory entries.
    private let data: UnsafeMutableRawPointer

    /// `heldBlocks` blocks of the file system's own bookkeeping, kept so that a
    /// disk asked twice for the same one is asked once.
    ///
    /// Write-through, and that word is the whole design. A cached *read* changes
    /// nothing about what reaches the medium or in what order, so the ordering
    /// rule on `barrier` goes on saying exactly what it said. A cached write
    /// would change both, and this format has no journal to argue with. The bill
    /// was 144 reads against 80 writes, so the reads were where the money was
    /// anyway.
    ///
    /// Coherent because this is the only writer: the mount token is what makes
    /// that true, and `dropCache` is for the one context where it is not.
    private let held: UnsafeMutableRawPointer

    /// Which block sits in each slot, or `noBlock`.
    private var tags = InlineArray<4, UInt32>(repeating: FileSystem.noBlock)

    /// The slot the next block evicts.
    ///
    /// Round-robin, because the alternative is a recency count per slot and the
    /// two hot blocks stay in either way. What matters more than the policy is
    /// that it is deterministic and allocates nothing.
    private var victim = 0

    public private(set) var plan: FSLayout.Plan

    /// Whether the disk was still marked mounted when it was found, which means
    /// the machine before this one went away without unmounting.
    ///
    /// Nothing is repaired on the strength of it. It is a fact reported, not a
    /// recovery attempted, which is the honest amount of crash safety a format
    /// with no log can offer.
    public private(set) var wasDirty: Bool = false

    /// What the clock says, for the timestamps on objects. Supplied by the
    /// caller because a file system has no business knowing what time it is.
    public var now: UInt64 = 0

    /// Where the last free object slot was found, and where the last run of
    /// blocks came from.
    ///
    /// Hints and not indexes: wrong is allowed, because both searches wrap and
    /// check. They exist because starting from zero every time turned making a
    /// file into a walk of the whole table, and the walk got longer as the disk
    /// filled, which is the shape of a system that gets slower the more you use
    /// it. In memory only: a hint that had to be written to the disk would cost
    /// a superblock write per create to save a few block reads.
    var objectHint: UInt32 = 0
    var blockHint : UInt32 = 0

    /// Set the first time the disk says something impossible, and never cleared.
    ///
    /// A record whose runs point below the data region, two records claiming one
    /// block, a directory entry naming something that does not agree it is
    /// there: none of these can be true of a disk this code wrote, so finding
    /// one means the disk is not the one that was written. From that moment
    /// nothing more is written to it.
    ///
    /// Read-only rather than refused outright, and that is the whole of the
    /// policy: what is still readable is worth reading, and the next write is
    /// what would turn damage into damage nobody can undo. It is never cleared,
    /// because nothing here knows how to be sure.
    public private(set) var corrupted = false

    /// Set the first time the device refuses anything, and never cleared.
    ///
    /// It exists because a disk that has stopped answering looks exactly like a
    /// disk that is full: the bitmap reads as all-taken and the allocator runs
    /// off the end. Without this, running out of disk and losing the disk are
    /// the same message, and they are not the same problem.
    public private(set) var deviceStopped = false

    let sectorsPerBlock: UInt64


    /// Sets the fields up over `device` without touching a single sector.
    ///
    /// Private, and that is the whole of this design: a `FileSystem` that has
    /// not read a superblock is not a mounted one, and the only two ways to get
    /// one from outside are `mount` and `format`. They used to be one door with
    /// a fall-through, which is how an unreadable disk got erased.
    private init?(
        over device : Device,
             scratch: UnsafeMutableRawPointer
    ) {

        guard let plan = FSLayout.Plan(
            sectorCount: device.sectorCount,
            sectorSize : device.sectorSize
        ) else { return nil }

        self.device = device
        self.plan   = plan
        self.meta   = scratch
        self.data   = scratch.advanced(by: Int(FSLayout.blockSize))
        self.held   = scratch.advanced(by: Int(FSLayout.blockSize) * 2)

        self.sectorsPerBlock = FSLayout.blockSize / device.sectorSize

        guard sectorsPerBlock > 0, sectorsPerBlock <= device.maximumRun else { return nil }
    }


    /// Mounts what is already on `device`, and says what it found.
    ///
    /// Writes nothing it did not recognise. A disk this refuses comes back
    /// byte for byte as it was, whatever the reason for the refusal: that is
    /// the point of there being five answers instead of two, and of none of
    /// them being `format`.
    ///
    /// The one write a successful mount does is the mounted mark, after the
    /// disk has been recognised, so that the next boot can tell an orderly
    /// shutdown from a power cut.
    public static func mount(
        _ device : Device,
          scratch: UnsafeMutableRawPointer
    ) -> (disk: FileSystem?, found: FSMount) {

        guard var disk = FileSystem(over: device, scratch: scratch) else {
            return (nil, .unusable)
        }

        let found = disk.readSuperblock()
        guard case .ok = found else { return (nil, found) }

        guard disk.mark(state: 1) == .ok else { return (nil, .deviceFailed) }

        return (disk, .ok)
    }


    /// Writes a fresh file system over whatever is on `device`, and mounts it.
    ///
    /// Everything that was there is gone. Nothing is read first and nothing is
    /// decided here: whoever calls this has already decided, which is exactly
    /// why it is a door of its own rather than somewhere `mount` can end up.
    public static func format(
        _ device : Device,
          scratch: UnsafeMutableRawPointer
    ) -> (disk: FileSystem?, made: FSStatus) {

        guard var disk = FileSystem(over: device, scratch: scratch) else {
            return (nil, .deviceFailed)
        }

        let made = disk.writeFreshFormat()
        guard made == .ok else { return (nil, made) }

        guard disk.mark(state: 1) == .ok else { return (nil, .deviceFailed) }

        return (disk, .ok)
    }


    /// Clears the mounted mark. A disk unmounted this way comes back clean.
    public mutating func unmount() -> FSStatus {
        mark(state: 0)
    }


    // MARK: - Blocks

    mutating func readBlock(
        _    index : UInt32,
        into buffer: UnsafeMutableRawPointer
    ) -> FSStatus {
        
        guard index < plan.totalBlocks else { return .deviceFailed }

        if let slot = slot(holding: index) {
            buffer.copyMemory(from: page(slot), byteCount: Int(FSLayout.blockSize))
            return .ok
        }

        guard device.read(
            sectorsPerBlock,
            from: UInt64(index) * sectorsPerBlock,
            into: buffer
            
        ) == .ok else {
            deviceStopped = true
            return .deviceFailed
        }

        keep(index, from: buffer)

        return .ok
    }

    mutating func writeBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {

        // Every change to this disk comes through here, which is what makes one
        // guard enough to hold the whole volume still. Ahead of the cache.
        guard !corrupted else { return .quarantined }

        guard index < plan.totalBlocks else { return .deviceFailed }

        forget(index)

        guard device.write(
            sectorsPerBlock,
            to  : UInt64(index) * sectorsPerBlock,
            from: buffer
            
        ) == .ok else {
            deviceStopped = true
            return .deviceFailed
        }

        keep(index, from: buffer)

        return .ok
    }


    /// Whether a block is one of the file system's own.
    ///
    /// Everything below the data region is bookkeeping - the superblock, the
    /// bitmap, the object table - and everything at or above it is somebody's
    /// bytes. That line is the whole of what is cached, and it is drawn there
    /// because the measurement said so: the re-reads were all metadata, and file
    /// contents already go through a pipelined loop that never comes past here.
    private func isOwn(_ index: UInt32) -> Bool { index < plan.dataStart }

    private func slot(holding index: UInt32) -> Int? {
        guard isOwn(index) else { return nil }

        for slot in 0..<Self.heldBlocks where tags[slot] == index { return slot }
        return nil
    }

    private func page(_ slot: Int) -> UnsafeMutableRawPointer {
        held.advanced(by: slot * Int(FSLayout.blockSize))
    }

    /// Puts a block in the next slot, over whatever was there.
    private mutating func keep(
        _    index : UInt32,
        from buffer: UnsafeRawPointer
    ) {
    
        guard isOwn(index) else { return }

        // Any older copy goes first. Two slots wearing one tag is a lookup that
        // finds the earlier one, and that is the stale one as often as not.
        forget(index)

        page(victim).copyMemory(
            from     : buffer,
            byteCount: Int(FSLayout.blockSize)
        )
        tags[victim] = index
        victim = (victim + 1) % Self.heldBlocks
    }

    private mutating func forget(_ index: UInt32) {
        for slot in 0..<Self.heldBlocks where tags[slot] == index {
            tags[slot] = Self.noBlock
        }
    }

    /// Forgets every block held, for when something else has written the disk.
    ///
    /// A cache cannot see another writer, and nothing on a mounted volume is
    /// one: the mount token is exactly the promise that this is the only hand on
    /// it. What is not covered by that promise is a test that damages a disk
    /// behind the file system's back, and an assertion about what reached the
    /// medium, which must go and look rather than be told.
    mutating func dropCache() {
        for slot in 0..<Self.heldBlocks { tags[slot] = Self.noBlock }
    }

    /// The reason behind a request that came back empty-handed.
    ///
    /// Three different things look identical to a search: there is nothing
    /// there, the disk stopped answering, and the disk is being held still
    /// because it contradicted itself. Answering the first for all three sends
    /// the caller looking for a bug in its own numbers - and a quarantine
    /// reported as "no room left" is the worst of the three, because there is
    /// room and looking for more will not help.
    func explain(_ plain: FSStatus) -> FSStatus {
        if corrupted { return .quarantined }
        return deviceStopped ? .deviceFailed : plain
    }


    /// Holds the volume still, for good.
    ///
    /// Called from the two places that read structure off the disk, and from
    /// nowhere else: there are only two, and both of them are asking the disk to
    /// describe itself.
    mutating func quarantine() {
        corrupted = true
    }


    /// Makes everything written so far true of the medium, so that nothing
    /// written afterwards can reach it first.
    ///
    /// This is what this format has instead of a journal, and it is the whole of
    /// it. The rule it serves is one sentence:
    ///
    /// > The map says a block is used for at least as long as any record points
    /// > at it.
    ///
    /// So blocks are claimed before the record that owns them is published, and
    /// released only after the record that stopped pointing at them is. Both
    /// halves leave the same residue when a machine dies in the middle - blocks
    /// marked used that nobody owns - and that residue is a leak, which `check`
    /// rebuilds away. What the rule makes impossible is the other residue: a
    /// record pointing at a block the map calls free, which the next allocation
    /// hands to somebody else and no check can put right afterwards.
    ///
    /// Without this call the ordering is a wish about a write cache rather than
    /// a fact about a disk.
    ///
    /// Except on a disk that has no write cache, which is a thing the device
    /// declares rather than something guessed at here: on one of those a write
    /// is on the medium when its request comes back, so the completions already
    /// are the order and asking for it costs a round trip that buys nothing.
    /// See `BlockDurability`, which is there because "completed", "ordered" and
    /// "durable" are three different claims and a file system with no journal
    /// has only these to build out of.
    mutating func barrier() -> FSStatus {

        guard device.durability == .onFlush else { return .ok }

        return device.flush() == .ok ? .ok : .deviceFailed
    }


    mutating func zeroBlock(_ index: UInt32) -> FSStatus {
        meta.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        return writeBlock(index, from: meta)
    }


    // MARK: - The superblock

    /// Reads block zero and says what is on it.
    ///
    /// Four ways to say no, and they are four because they are four different
    /// situations: an empty disk is the only one anybody should be willing to
    /// write over, and it used to be indistinguishable from the other three.
    private mutating func readSuperblock() -> FSMount {

        guard readBlock(0, into: meta) == .ok else { return .deviceFailed }

        // Blank is the whole block, not the magic. A superblock whose magic was
        // lost half way through a write still has every other field, and
        // calling that an empty disk is how a torn write became an erase.
        if isBlockZeroEmpty() { return .blank }

        let parts = FSLayout.magicParts(
            meta.loadUnaligned(fromByteOffset: Field.magic, as: UInt64.self)
        )

        // Not our format at all: somebody else's disk, or one damaged past
        // recognising. Either way not ours to write.
        guard parts.family == FSLayout.magicFamily else { return .corrupt }

        // Ours, in a version this build does not know. Refused by name, so that
        // an older machine meeting a newer disk says so instead of treating an
        // unfamiliar number as an empty disk.
        guard parts.version == FSLayout.formatVersion else {
            return .unsupportedVersion(parts.version)
        }

        // The layout is a calculation, so a superblock that disagrees with it
        // describes a disk this is not: a torn write, a bad block, or an image
        // that was resized underneath its own superblock.
        guard meta.loadUnaligned(fromByteOffset: Field.blockSize,   as: UInt32.self) == UInt32(FSLayout.blockSize),
              meta.loadUnaligned(fromByteOffset: Field.totalBlocks, as: UInt32.self) == plan.totalBlocks,
              meta.loadUnaligned(fromByteOffset: Field.dataStart,   as: UInt32.self) == plan.dataStart,
              meta.loadUnaligned(fromByteOffset: Field.objectCount, as: UInt32.self) == plan.objectCount
        else { return .corrupt }

        wasDirty = meta.loadUnaligned(fromByteOffset: Field.state, as: UInt32.self) != 0

        return .ok
    }


    /// Whether every byte of the superblock just read is zero.
    ///
    /// Eight bytes at a time over one block, which is five hundred and twelve
    /// comparisons on the one path where being sure is worth more than being
    /// quick: the answer decides whether a disk may be written over.
    private func isBlockZeroEmpty() -> Bool {

        let words = Int(FSLayout.blockSize) / 8

        for index in 0..<words
        where meta.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self) != 0 {
            return false
        }

        return true
    }


    private mutating func mark(state: UInt32) -> FSStatus {
        guard readBlock(0, into: meta) == .ok else { return .deviceFailed }

        meta.storeBytes(of: state, toByteOffset: Field.state, as: UInt32.self)

        return writeBlock(0, from: meta)
    }


    /// Writes an empty file system over whatever was there.
    /// Lays a fresh format down over block zero and the bookkeeping behind it.
    ///
    /// Private on purpose: reachable only through the static `format`, so there
    /// is no way to erase a disk that does not read as a deliberate act at the
    /// call site.
    private mutating func writeFreshFormat() -> FSStatus {

        for block in 0..<plan.dataStart {
            guard zeroBlock(block) == .ok else { return .deviceFailed }
        }

        // Everything before the data region is in use from the moment it exists.
        guard setRange(
            start: 0,
            count: plan.dataStart,
            used : true
        ) == .ok else { return .deviceFailed }

        // The root is a container, not a folder: it is the machine itself, and
        // every block that is not the file system's own bookkeeping is its room
        // to give away.
        var root = FSObject(kind: .container, created: now)
        root.quota     = plan.totalBlocks - plan.dataStart
        root.container = FSLayout.rootObject
        root.parent    = FSLayout.rootObject

        guard store(root, at: FSLayout.rootObject) == .ok else { return .deviceFailed }

        meta.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        meta.storeBytes(of: FSLayout.magic,             toByteOffset: Field.magic,       as: UInt64.self)
        meta.storeBytes(of: UInt32(FSLayout.blockSize), toByteOffset: Field.blockSize,   as: UInt32.self)
        meta.storeBytes(of: plan.totalBlocks,           toByteOffset: Field.totalBlocks, as: UInt32.self)
        meta.storeBytes(of: plan.bitmapStart,           toByteOffset: Field.bitmapStart, as: UInt32.self)
        meta.storeBytes(of: plan.bitmapBlocks,          toByteOffset: Field.bitmapCount, as: UInt32.self)
        meta.storeBytes(of: plan.tableStart,            toByteOffset: Field.tableStart,  as: UInt32.self)
        meta.storeBytes(of: plan.tableBlocks,           toByteOffset: Field.tableCount,  as: UInt32.self)
        meta.storeBytes(of: plan.dataStart,             toByteOffset: Field.dataStart,   as: UInt32.self)
        meta.storeBytes(of: plan.objectCount,           toByteOffset: Field.objectCount, as: UInt32.self)
        meta.storeBytes(of: FSLayout.rootObject,        toByteOffset: Field.rootObject,  as: UInt32.self)
        meta.storeBytes(of: UInt32(0),                  toByteOffset: Field.state,       as: UInt32.self)

        let machine = FSLayout.defaultMachineName
        let letters = meta.advanced(by: Field.name).assumingMemoryBound(to: UInt8.self)

        for index in 0..<min(machine.utf8CodeUnitCount, FSLayout.machineNameLimit) {
            letters[index] = machine.utf8Start[index]
        }

        wasDirty = false

        return writeBlock(0, from: meta)
    }


    /// The machine's own name, written into `destination`, which must hold
    /// `FSLayout.machineNameLimit` bytes. Answers how long it is.
    public mutating func machineName(into destination: UnsafeMutableRawPointer) -> Int {

        guard readBlock(0, into: meta) == .ok else { return 0 }

        let letters = meta.advanced(by: Field.name).assumingMemoryBound(to: UInt8.self)
        let out     = destination.assumingMemoryBound(to: UInt8.self)

        var length = 0
        while length < FSLayout.machineNameLimit, letters[length] > 0x20, letters[length] < 0x7F {
            out[length] = letters[length]
            length += 1
        }

        return length
    }


    // MARK: - For the extensions

    var metaBuffer: UnsafeMutableRawPointer { meta }
    var dataBuffer: UnsafeMutableRawPointer { data }
}
