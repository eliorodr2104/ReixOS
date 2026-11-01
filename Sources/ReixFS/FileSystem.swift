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

    /// How much scratch memory to hand `mount` or `format` for a disk of this
    /// geometry. Contiguous, and all of it used.
    ///
    /// Six loose blocks, `heldBlocks` cached ones, then three regions that grow
    /// with the disk: the name scrub's target bitset, the journal's arena, and
    /// the checksum of every bitmap, table and sum block.
    ///
    /// The third loose one is the journal header's: replay copies an after-image
    /// out of a payload block and into its home block, and doing that through
    /// either of the first two would be doing it through a buffer the operation
    /// around it is holding. The fourth is the scan's accumulator - a thousand and
    /// twenty-four counters over one page - the fifth the name scrub's
    /// descriptor workspace, and the sixth the new checksums an overwrite has
    /// declared, which outlive every buffer the write passes through.
    ///
    /// The arena is one block per journal record, sixteen, and never fewer than
    /// one per bitmap block: outside a transaction it is where a scan builds the
    /// whole block map at once, which is what makes a scan one pass over the
    /// object table instead of one pass per bitmap block. Up to two gibibytes
    /// that costs nothing the journal was not already asking for.
    ///
    /// A device no file system fits gets the smallest shape; `mount` refuses it.
    public static func scratchBytes(sectorCount: UInt64, sectorSize: UInt64) -> Int {
        let fixed = 6 + heldBlocks
        guard let plan = FSLayout.Plan(sectorCount: sectorCount, sectorSize: sectorSize) else {
            return Int(FSLayout.blockSize) * (fixed + 1 + FSJournal.capacity + 1)
        }

        return Int(FSLayout.blockSize)
            * (fixed + targetBlocks(plan) + arenaBlocks(plan) + knownSumBlocks(plan))
    }

    /// Enough scratch for every geometry `mount` and `format` accept.
    ///
    /// The regions only grow with the disk, so the largest declared geometry is
    /// the most any of them asks for. The unchecked doors take bigger disks and
    /// want `scratchBytes(sectorCount:sectorSize:)` instead.
    public static var scratchBytes: Int {
        scratchBytes(
            sectorCount: UInt64(FSLayout.maxSupportedBlocks) * (FSLayout.blockSize / 512),
            sectorSize : 512
        )
    }

    /// One bit per object, for the name scrub's duplicate-target check.
    static func targetBlocks(_ plan: FSLayout.Plan) -> Int {
        Int(FSLayout.divideUp(UInt64(plan.objectCount), FSLayout.blockSize * 8))
    }

    static func arenaBlocks(_ plan: FSLayout.Plan) -> Int {
        Int(plan.bitmapBlocks) > FSJournal.capacity ? Int(plan.bitmapBlocks) : FSJournal.capacity
    }

    /// Four bytes per bitmap, table and sum block. See `sums`.
    static func knownSumBlocks(_ plan: FSLayout.Plan) -> Int {
        Int(FSLayout.divideUp(
            4 * (UInt64(plan.bitmapBlocks) + UInt64(plan.tableBlocks) + UInt64(plan.sumBlocks)),
            FSLayout.blockSize
        ))
    }

    public var device: Device

    /// Metadata: the superblock, the bitmap, the object table.
    private let meta: UnsafeMutableRawPointer

    /// File contents and directory entries.
    private let data: UnsafeMutableRawPointer

    /// The journal's own block of scratch. Never held across a call that could
    /// stage or commit.
    private let jrnl: UnsafeMutableRawPointer

    /// The scan's accumulator. Only a scan touches it.
    private let tally: UnsafeMutableRawPointer

    /// The deep name scan's target bitset, one bit per object. Only a scan
    /// touches it.
    private let targets: UnsafeMutableRawPointer

    /// The deep name scan's descriptor workspace. Only a scan touches it.
    private let scrub: UnsafeMutableRawPointer

    /// The new checksum of every block `unsettled` names, in its order, for as
    /// long as it names them. See `declare`.
    private let declared: UnsafeMutableRawPointer

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

    /// Sixteen blocks, one per journal record: the after-image of every block
    /// this transaction has changed, as it stands.
    ///
    /// **This is the coalescing.** Staging used to write its image straight to the
    /// journal's payload block, so a transaction that changed one bitmap block
    /// four times wrote four payloads; now it overwrites the image here and the
    /// commit writes each one once. Nothing on the disk depends on what is in here
    /// until the commit writes it out, which is also why an abandoned transaction
    /// touches the medium not at all.
    private let images: UnsafeMutableRawPointer

    /// What every bitmap, table and sum block should checksum to: the bitmap's
    /// first, then the table's and the sum region's, which are adjacent, four
    /// bytes each.
    ///
    /// Moved by every write of one of those blocks and asked by every read of
    /// one off the medium, so a block that changed behind this process's back -
    /// rot, a write the disk lost, a hand that is not this one - is refused the
    /// first time it is read instead of being believed. It is what lets a clean
    /// mount skip the table: the seal hands these over and the reads check them.
    private let sums: UnsafeMutableRawPointer

    /// Blocks a `prepared` header on the disk names as overwritten in place and
    /// whose checksums have not been settled against the medium yet. See
    /// `settle`.
    ///
    /// Set when a write declares them and when a mount finds them, cleared once
    /// a commit carries their checksums or a settle has made them true.
    var unsettled = FSJournal.Intent()

    /// Whether `declared` holds the new checksum of every block `unsettled`
    /// names. Not after a mount that found a header torn before its blocks were
    /// written, and then only the old checksums are true.
    var declaredKnown = false

    /// Whether `sums` describes the disk yet.
    ///
    /// Not on a dirty mount until its scan has read every one of those blocks:
    /// until then a read records what it found instead of judging it, because
    /// there is nothing to judge it against. True from a format, a verified
    /// seal, or a whole scan, and from then on every read is checked.
    var sumsKnown = false

    /// Whether a contradiction a scan finds holds the volume still.
    ///
    /// Always, except in the scan `unmount` runs before sealing. There a finding
    /// means no seal and a clean mark, so the next mount checks in full and
    /// refuses: holding the volume would leave it marked mounted instead, and a
    /// recovering mount mends a room a clean one must report.
    var scanHolds = true

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

    var containerCount: Int? = nil

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

    /// The transaction being built, if one is.
    private var transaction = FSTransaction()

    /// Which transaction of *this mount* the next one is.
    ///
    /// In memory only, and it restarts at zero every mount - which is exactly why
    /// the number that goes on the disk carries the superblock generation with it.
    /// See `FSJournal.stamp`.
    private var transactions: UInt32 = 0

    /// The newest transaction the home blocks are known to hold.
    ///
    /// Read off the journal header at mount and moved by every commit, so a
    /// committed journal from an earlier mount is discarded rather than replayed
    /// over metadata that has moved on since. This is cross-mount stale-journal
    /// rejection on the current medium, not storage anti-rollback. Zero on a
    /// disk written by a build that did not stamp its journals, which no live
    /// mount ever matches.
    private var checkpoint: UInt64 = 0

    /// How many transactions this mount has committed.
    ///
    /// The other half of what makes a set of findings answerable. A scan is a
    /// statement about a moment, and a repair acting on one taken before a
    /// mutation would be freeing blocks whose owner was written afterwards. See
    /// `Findings.mutations`.
    private(set) var mutations: UInt64 = 0

    /// What the journal on the disk is holding, as far as this process knows.
    ///
    /// A transaction may only begin from an empty journal, and this is how that is
    /// known without reading a block per transaction: it is set from the disk at
    /// mount and moved by every path that writes a header.
    ///
    /// Three values and not a flag, because "not empty" is two different
    /// situations and only one of them may be tidied up from here. A `prepared`
    /// header was never promised, so a transaction that failed before its commit
    /// may clear it and carry on - which is what makes a volume usable again after
    /// the device recovers. A `committed` one is a promise, and the only thing
    /// allowed to finish it is a mount.
    private var journal: FSJournal.State = .committed

    /// The superblock this volume is mounted from, and which of the two copies it
    /// came out of.
    ///
    /// Held in memory because it is read on every `machineName` and written on
    /// every mount, unmount and rename, and because the *other* copy is where the
    /// next update goes: an update that overwrote the copy it was reading from
    /// would have no whole superblock at all for the length of one write.
    private var superblock: FSSuperblock? = nil
    private var liveSuperblock: UInt32 = FSLayout.superblockA


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

        let block = Int(FSLayout.blockSize)
        let grown = 6 + Self.heldBlocks

        self.device   = device
        self.plan     = plan
        self.meta     = scratch
        self.data     = scratch.advanced(by: block)
        self.jrnl     = scratch.advanced(by: block * 2)
        self.tally    = scratch.advanced(by: block * 3)
        self.scrub    = scratch.advanced(by: block * 4)
        self.declared = scratch.advanced(by: block * 5)
        self.held     = scratch.advanced(by: block * 6)
        self.targets  = scratch.advanced(by: block * grown)
        self.images   = scratch.advanced(by: block * (grown + Self.targetBlocks(plan)))
        self.sums     = scratch.advanced(
            by: block * (grown + Self.targetBlocks(plan) + Self.arenaBlocks(plan))
        )

        self.sectorsPerBlock = FSLayout.blockSize / device.sectorSize

        guard sectorsPerBlock > 0, sectorsPerBlock <= device.maximumRun else { return nil }
    }


    /// Mounts what is already on `device`, and says what it found.
    ///
    /// Writes nothing it did not recognise. A disk this refuses comes back
    /// byte for byte as it was, whatever the reason for the refusal: that is
    /// the point of there being six answers instead of two, and of none of
    /// them being `format`.
    ///
    /// The one write a successful mount does is the mounted mark, after the
    /// disk has been recognised, so that the next boot can tell an orderly
    /// shutdown from a power cut.
    public static func mount(
        _ device : Device,
          scratch: UnsafeMutableRawPointer
    ) -> (disk: FileSystem?, found: FSMount) {
        open(device, scratch: scratch, limited: true)
    }


    /// The same door without the geometry limit, for the measurements that set it.
    ///
    /// Internal, and the only caller is `ScaleTests`: the limit is a number read
    /// off the walks of a big disk, so something has to be able to open one.
    static func mountUnchecked(
        _ device : Device,
          scratch: UnsafeMutableRawPointer
    ) -> (disk: FileSystem?, found: FSMount) {
        open(device, scratch: scratch, limited: false)
    }


    private static func open(
        _ device : Device,
          scratch: UnsafeMutableRawPointer,
          limited: Bool
    ) -> (disk: FileSystem?, found: FSMount) {

        // First, and before anything is read, because there is no read-only
        // mount to fall back to: a mount marks the disk, so opening one at all
        // is already a write. A device that cannot say what a write achieves is
        // a device whose next power cut leaves this format in a state nothing
        // here can reason about.
        guard device.durability != .unknown else { return (nil, .durabilityUnknown) }

        guard var disk = FileSystem(over: device, scratch: scratch) else {
            return (nil, .unusable)
        }

        // Before a byte is read, and refused rather than served. See
        // `FSLayout.maxSupportedBlocks`.
        if limited, disk.plan.totalBlocks > FSLayout.maxSupportedBlocks {
            return (nil, .tooLarge(disk.plan.totalBlocks))
        }

        let found = disk.readSuperblocks()
        guard case .ok = found else { return (nil, found) }

        // The journal before anything is served. What it holds is metadata the
        // home blocks do not have yet, so a request answered before this would be
        // answered off a disk that is one transaction behind itself.
        let journal = disk.recoverJournal()
        guard journal.status == .ok else {
            return (nil, disk.corrupted ? .corrupt : .deviceFailed)
        }

        // Dirty is recovered, clean and sealed is believed, and any other clean
        // disk is checked in full, the way every clean mount used to be.
        if disk.wasDirty {
            guard disk.putRight().safeToServe else { return (nil, .corrupt) }
        } else {
            switch journal.quiet ? disk.openSeal() : .absent {
                case .verified    : break
                case .contradicted: return (nil, .corrupt)
                case .failed      : return (nil, .deviceFailed)

                case .absent:
                    guard disk.scan(.everything).safeToServe else { return (nil, .corrupt) }
            }
        }

        // A fresh generation, marked mounted, onto the copy that is *not* the one
        // just read. The next boot can then tell an orderly shutdown from a power
        // cut, and a cut in the middle of saying so costs the newer copy rather
        // than the only one.
        guard disk.publishSuperblock(state: 1) == .ok else { return (nil, .deviceFailed) }

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

        // The declared limit, before anything is written: laying a file system
        // down is a promise about a boot nobody has timed.
        if let plan = FSLayout.Plan(
            sectorCount: device.sectorCount, sectorSize: device.sectorSize
        ), plan.totalBlocks > FSLayout.maxSupportedBlocks {
            return (nil, .tooManyBlocks)
        }

        return formatUnchecked(device, scratch: scratch)
    }


    /// The same door without the geometry limit, for the measurements that set it.
    ///
    /// Internal, and the only caller is `ScaleTests`: the limit is a number read
    /// off a walk of a big disk, so something has to be able to make one. Nothing
    /// in the system reaches this - a disk it formatted would be refused by
    /// `mount` on the next boot, which is the honest end of that road.
    static func formatUnchecked(
        _ device : Device,
          scratch: UnsafeMutableRawPointer
    ) -> (disk: FileSystem?, made: FSStatus) {

        guard device.durability != .unknown else { return (nil, .durabilityUnknown) }

        guard var disk = FileSystem(over: device, scratch: scratch) else {
            return (nil, .deviceFailed)
        }

        // The mounted mark is part of the format now, written into both copies
        // as they are laid down. A separate write afterwards was a second chance
        // for the disk to be left saying nobody was using it while somebody was.
        let made = disk.writeFreshFormat()
        guard made == .ok else { return (nil, made) }

        return (disk, .ok)
    }


    /// Clears the mounted mark. A disk unmounted this way comes back clean.
    ///
    /// Refused while a transaction is open, because a clean mark over an
    /// unfinished one would be a disk that says it was shut down tidily and holds
    /// a journal saying otherwise.
    ///
    /// The volume is sealed on the way out when a full check finds it whole:
    /// the seal written and made durable before the clean mark that names it. A
    /// volume that does not add up is marked clean without a seal, so the next
    /// mount checks it in full.
    public mutating func unmount() -> FSStatus {

        guard !transaction.active else { return .busy }

        // Everything already written reaches the medium before the mark that says
        // it did.
        guard barrier() == .ok else { return .deviceFailed }

        return publishSuperblock(state: 0, seal: writeSeal())
    }


    // MARK: - Blocks

    mutating func readBlock(
        _    index : UInt32,
        into buffer: UnsafeMutableRawPointer
    ) -> FSStatus {

        guard index < plan.totalBlocks else { return .deviceFailed }

        // The cache first, and it holds staged content as readily as home
        // content: staging puts the after-image here under the target's own
        // number, so a block this transaction changed reads back changed.
        if let slot = slot(holding: index) {
            buffer.copyMemory(from: page(slot), byteCount: Int(FSLayout.blockSize))
            return .ok
        }

        // Evicted, and staged. The home block still holds what was there before,
        // so the after-image has to come out of the arena - without this an
        // operation that stages a bitmap block and then reads it again reads what
        // it had just replaced. No round trip: the image has not been near the
        // disk yet and will not be until the commit.
        if let slot = transaction.staging(index) {
            buffer.copyMemory(from: image(slot), byteCount: Int(FSLayout.blockSize))
            return .ok
        }

        guard device.read(
            sectorsPerBlock,
            from: UInt64(index) * sectorsPerBlock,
            into: buffer
            
        ) == .ok else { return deviceRefused() }

        // Off the medium, so asked whether it is what was last written there.
        guard believe(index, read: buffer) else {
            quarantine()
            return .quarantined
        }

        keep(index, from: buffer)

        return .ok
    }


    /// Where `index`'s checksum sits in `sums`, if it is a bitmap, table or sum
    /// block.
    private func sumSlot(of index: UInt32) -> Int? {
        if index >= plan.bitmapStart, index - plan.bitmapStart < plan.bitmapBlocks {
            return Int(index - plan.bitmapStart)
        }
        if index >= plan.tableStart, index < plan.dataStart {
            return Int(plan.bitmapBlocks) + Int(index - plan.tableStart)
        }
        return nil
    }

    /// What `index` should checksum to, for the seal. Bitmap, table and sum
    /// blocks only.
    func expectedSum(of index: UInt32) -> UInt32? {
        guard let slot = sumSlot(of: index) else { return nil }
        return sums.loadUnaligned(fromByteOffset: slot * 4, as: UInt32.self)
    }

    /// Sets what `index` should checksum to, for a seal being loaded.
    mutating func expect(_ sum: UInt32, of index: UInt32) {
        guard let slot = sumSlot(of: index) else { return }
        sums.storeBytes(of: sum, toByteOffset: slot * 4, as: UInt32.self)
    }

    /// Whether a block just read off the medium is the one this process last
    /// knew to be there. Recorded instead of judged while `sumsKnown` is false.
    private mutating func believe(_ index: UInt32, read buffer: UnsafeRawPointer) -> Bool {
        guard let slot = sumSlot(of: index) else { return true }

        let sum = FSChecksum.over(buffer, count: Int(FSLayout.blockSize))

        guard sumsKnown else {
            sums.storeBytes(of: sum, toByteOffset: slot * 4, as: UInt32.self)
            return true
        }

        return sums.loadUnaligned(fromByteOffset: slot * 4, as: UInt32.self) == sum
    }


    /// One block, off the medium, with no cache and no transaction in the way.
    ///
    /// For the journal, the superblocks and a replay: the three readers that want
    /// the bytes that are actually there.
    mutating func readRawBlock(
        _    index : UInt32,
        into buffer: UnsafeMutableRawPointer
    ) -> FSStatus {

        guard index < plan.totalBlocks else { return .deviceFailed }

        guard device.read(
            sectorsPerBlock,
            from: UInt64(index) * sectorsPerBlock,
            into: buffer

        ) == .ok else { return deviceRefused() }

        return .ok
    }


    /// Somebody's bytes.
    ///
    /// Written straight to the medium and never journalled. What a transaction
    /// promises is that the metadata is coherent, not that a power cut cannot
    /// land in the middle of a file: journalling file contents would double every
    /// write for a guarantee nobody asked for.
    ///
    /// Its checksum is metadata and is journalled, staged before the block is
    /// written: a write whose checksum cannot be staged does not happen. The new
    /// checksum reaches its home block only with the commit, so a block
    /// overwritten in place must have been named first. See `declare`.
    mutating func writeDataBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {

        let summed = stageSum(of: index, for: buffer)
        guard summed == .ok else { return summed }

        return writeHomeBlock(index, from: buffer)
    }


    /// A block in the data region that goes through the journal with its
    /// checksum: the partly filled last block of a file an append rewrites, so
    /// it is old or new after a power cut, never torn.
    mutating func stageDataBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {

        let summed = stageSum(of: index, for: buffer)
        guard summed == .ok else { return summed }

        return stageStructuralBlock(index, from: buffer)
    }


    /// Stages `buffer`'s checksum as what data block `index` holds.
    private mutating func stageSum(
        of  index : UInt32,
        for buffer: UnsafeRawPointer
    ) -> FSStatus {

        guard index >= plan.dataStart else { return .deviceFailed }

        let home   = sumBlock(of: index)
        let loaded = readBlock(home, into: jrnl)
        guard loaded == .ok else { return loaded }

        jrnl.storeBytes(
            of          : FSChecksum.over(buffer, count: Int(FSLayout.blockSize)),
            toByteOffset: sumOffset(of: index),
            as          : UInt32.self
        )

        return stageStructuralBlock(home, from: jrnl)
    }


    // MARK: - File data checksums

    /// Which block of the sum region holds `block`'s checksum.
    func sumBlock(of block: UInt32) -> UInt32 {
        plan.sumStart + block / UInt32(FSLayout.sumsPerBlock)
    }

    /// Where in that block it sits.
    func sumOffset(of block: UInt32) -> Int {
        Int(block % UInt32(FSLayout.sumsPerBlock)) * 4
    }

    /// What file block `block` should checksum to, when the sum block holding
    /// it is in the cache. Nil when finding out means a read.
    func heldDataSum(of block: UInt32) -> UInt32? {
        guard let slot = slot(holding: sumBlock(of: block)) else { return nil }

        return page(slot).loadUnaligned(fromByteOffset: sumOffset(of: block), as: UInt32.self)
    }

    /// What file block `block` should checksum to, reading its sum block when
    /// it is not in hand. The sum block is checked like any table block.
    mutating func dataSum(of block: UInt32) -> (status: FSStatus, sum: UInt32) {
        if let sum = heldDataSum(of: block) { return (.ok, sum) }

        let loaded = readBlock(sumBlock(of: block), into: jrnl)
        guard loaded == .ok else { return (loaded, 0) }

        return (.ok, jrnl.loadUnaligned(fromByteOffset: sumOffset(of: block), as: UInt32.self))
    }

    /// One block of somebody's file, or `damaged` instead of bytes that are not
    /// the ones last written there.
    ///
    /// Rot, a write the disk lost, a write that landed at the wrong address:
    /// each leaves a block that does not checksum to what its last write said,
    /// and each used to be handed to the reader as the file. Refused per
    /// request and not by holding the volume: nothing else on the disk is built
    /// on a file's bytes, and a whole-block write over it puts it right.
    mutating func readDataBlock(
        _    index : UInt32,
        into buffer: UnsafeMutableRawPointer
    ) -> FSStatus {

        let expected = dataSum(of: index)
        guard expected.status == .ok else { return expected.status }

        let loaded = readBlock(index, into: buffer)
        guard loaded == .ok else { return loaded }

        return FSChecksum.over(buffer, count: Int(FSLayout.blockSize)) == expected.sum
            ? .ok : .damaged
    }


    /// Names, on the disk, the blocks a write is about to overwrite in place
    /// and the checksum each will have, and makes that durable before the first
    /// of them is written. The checksums are in `declaredBuffer` already.
    ///
    /// One header and one barrier, paid only by a write that lands on blocks the
    /// file already has. Until the commit, a power cut can leave any of those
    /// holding new bytes under an old checksum, and this is how the mount after
    /// it knows which. See `FSJournal.Intent`.
    mutating func declare(_ intent: FSJournal.Intent) -> FSStatus {

        transaction.intend(intent)

        // Owed from here whether or not the header lands: a header the device
        // refused may still be on the medium.
        unsettled     = intent
        declaredKnown = true
        journal       = .prepared

        guard writeJournalHeader(transaction.declaration()) == .ok, barrier() == .ok else {
            return staging(refused: .deviceFailed)
        }

        return .ok
    }


    /// Judges every block `unsettled` names against what the medium holds, and
    /// makes the verdict durable. What clearing a `prepared` header owes.
    ///
    /// Each named block was meant to hold the old bytes or the new ones, and
    /// the sum region and the declaration say what each of those checksums to.
    /// One that matches the new checksum takes it; one that matches the old is
    /// left; anything else, rot or a block torn between the two, keeps the old
    /// checksum and reads as damaged. Lost and said so, never believed.
    ///
    /// Only the named entries change, and only towards the new checksum, so a
    /// power cut half way through leaves a sum block that the next settle
    /// judges the same way.
    private mutating func settle() -> FSStatus {

        guard !unsettled.isEmpty else { return .ok }

        var loaded = Self.noBlock
        var named  = 0

        for run in 0..<unsettled.count {
            let extent = unsettled.runs[run]

            for block in extent.start..<(extent.start + extent.count) {
                let home = sumBlock(of: block)

                if home != loaded {
                    if loaded != Self.noBlock {
                        guard writeHomeBlock(loaded, from: meta) == .ok else { return explain(.deviceFailed) }
                    }

                    guard readBlock(home, into: meta) == .ok else { return explain(.deviceFailed) }
                    loaded = home
                }

                guard readRawBlock(block, into: data) == .ok else { return .deviceFailed }

                let found = FSChecksum.over(data, count: Int(FSLayout.blockSize))
                let new   = declared.loadUnaligned(fromByteOffset: named * 4, as: UInt32.self)
                named += 1

                guard declaredKnown, found == new else { continue }

                meta.storeBytes(of: new, toByteOffset: sumOffset(of: block), as: UInt32.self)
            }
        }

        guard writeHomeBlock(loaded, from: meta) == .ok, barrier() == .ok else {
            return explain(.deviceFailed)
        }

        unsettled     = FSJournal.Intent()
        declaredKnown = false
        return .ok
    }


    /// The bitmap, the object table, a directory block: the disk's own
    /// bookkeeping.
    ///
    /// Inside a transaction the after-image goes into the arena and the home block
    /// is not touched until the transaction is committed. That is the whole of
    /// what the journal buys: a change to several of these either all reaches the
    /// disk or none of it does.
    ///
    /// **No I/O at all.** The image is copied into memory and the medium hears
    /// nothing until `commit`, which writes each of the sixteen once. Staging used
    /// to write a payload block per call, so a transaction touching one bitmap
    /// block four times paid four writes for one block of change.
    ///
    /// Outside a transaction it is **refused**. That refusal is the guarantee:
    /// a mutation added later that forgets to open a transaction cannot quietly
    /// write the disk's bookkeeping straight to its home block, because there is
    /// no longer a path from here to the medium that does not go through a
    /// journal. The two exceptions are named out loud in `FSTransaction.Mode`
    /// and are the paths with nothing to be coherent with: a fresh format, and a
    /// replay.
    mutating func stageStructuralBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {

        guard transaction.active else {
            switch transaction.mode {
                case .formatting, .recovering:
                    return writeHomeBlock(index, from: buffer)

                case .serving:
                    return .noTransaction
            }
        }

        guard !corrupted else { return staging(refused: .quarantined) }

        // The front of the disk is not somewhere an after-image may point. A
        // record naming the journal header would have replay rewrite the thing
        // that says what to replay.
        guard index >= FSLayout.reservedBlocks, index < plan.totalBlocks else {
            return staging(refused: .deviceFailed)
        }

        let slot: Int

        switch transaction.slot(for: index) {
            case .full:
                // Refused here and not truncated at the commit: a transaction
                // that can be cut short is not a transaction.
                transaction.overflowed()
                return staging(refused: .tooManyChanges)

            case .again(let index): slot = index
            case .fresh(let index): slot = index
        }

        // Into the arena, and nowhere near the disk. The image the medium gets is
        // whichever one this transaction leaves here, written once at the commit.
        image(slot).copyMemory(from: buffer, byteCount: Int(FSLayout.blockSize))

        transaction.staged(
            index,
            at      : slot,
            checksum: FSChecksum.over(buffer, count: Int(FSLayout.blockSize))
        )

        // And into the cache under the *target's* number, so the rest of the
        // operation reads what it just wrote without a trip to the journal. The
        // cache is coherent either way it is abandoned: a commit writes the same
        // bytes to the home block, and an abort drops the whole of it.
        forget(index)
        keep(index, from: buffer)

        return .ok
    }


    /// The journal, the superblocks, a fresh format and a replay. Nothing else.
    mutating func writeRawBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {
        writeHomeBlock(index, from: buffer)
    }


    /// Onto the medium, at the block's own address.
    ///
    /// The one place this file system writes anything, which is what makes a
    /// single guard enough to hold the whole volume still.
    private mutating func writeHomeBlock(
        _   index  : UInt32,
        from buffer: UnsafeRawPointer
    ) -> FSStatus {

        guard !corrupted else { return staging(refused: .quarantined) }

        guard index < plan.totalBlocks else { return staging(refused: .deviceFailed) }

        forget(index)

        guard device.write(
            sectorsPerBlock,
            to  : UInt64(index) * sectorsPerBlock,
            from: buffer
            
        ) == .ok else { return deviceRefused() }

        // Only once the device has taken it. A refused write left the old bytes,
        // and the old checksum is still the true one.
        if sumSlot(of: index) != nil {
            expect(FSChecksum.over(buffer, count: Int(FSLayout.blockSize)), of: index)
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
    private func isOwn(_ index: UInt32) -> Bool {
        index >= plan.bitmapStart && index < plan.dataStart
    }

    private func slot(holding index: UInt32) -> Int? {
        guard isOwn(index) else { return nil }

        for slot in 0..<Self.heldBlocks where tags[slot] == index { return slot }
        return nil
    }

    private func page(_ slot: Int) -> UnsafeMutableRawPointer {
        held.advanced(by: slot * Int(FSLayout.blockSize))
    }

    /// Where record `slot`'s after-image lives while the transaction is open.
    private func image(_ slot: Int) -> UnsafeMutableRawPointer {
        images.advanced(by: slot * Int(FSLayout.blockSize))
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


    /// Marks the open transaction unable to commit, and hands `status` back for
    /// the caller to return.
    ///
    /// Every structural write goes through one door, so the calls here are what
    /// make a refused staging call fatal to the whole transaction even when the
    /// operation above it drops the status on the floor. See
    /// `FSTransaction.stickyFailure`.
    @discardableResult
    mutating func staging(refused status: FSStatus) -> FSStatus {
        transaction.failed(status)
        return status
    }


    /// The device refused, so nothing more is expected of it and nothing built
    /// on it may be committed.
    private mutating func deviceRefused() -> FSStatus {
        deviceStopped = true
        return staging(refused: .deviceFailed)
    }


    /// Whether the open transaction has room for the images of every block from
    /// `first` through `last`, and refuses it whole when it has not.
    ///
    /// `ok` outside a transaction: a fresh format and a replay write home blocks
    /// directly and have no journal to run out of.
    mutating func roomToStage(
        from first: UInt32,
        through last: UInt32
    ) -> FSStatus {

        guard transaction.active else { return .ok }
        guard !transaction.room(from: first, through: last) else { return .ok }

        transaction.overflowed()
        return staging(refused: .tooManyChanges)
    }


    /// Holds the volume still, for good.
    ///
    /// Called from the places that read structure off the disk and find it
    /// impossible: a record that cannot be true, a journal header that is not
    /// one, a payload that does not match the checksum the header carries. Every
    /// one of them is the disk contradicting itself, which is not a request
    /// failing.
    mutating func quarantine() {
        corrupted = true

        // Nothing more will be written to this volume, so a transaction open
        // over it is one that must not be committed either.
        transaction.failed(.quarantined)
    }


    /// Makes everything written so far true of the medium, so that nothing
    /// written afterwards can reach it first.
    ///
    /// **Only the journal calls this now.** It used to be the whole of what this
    /// format had instead of one: every operation arranged its writes in an order
    /// whose every stopping point left something true, and put one of these
    /// between the halves to make the order a fact about the disk rather than a
    /// wish about a write cache. Those orderings are gone - the transaction is
    /// the order - and so are the calls that made them true. What is left is the
    /// four in the commit protocol and the ones that publish a superblock, which
    /// is the same mechanism used in one place instead of six.
    ///
    /// Nothing on a disk that has no write cache, which is a thing the device
    /// declares rather than something guessed at here: on one of those a write
    /// is on the medium when its request comes back, so the completions already
    /// are the order and asking for it costs a round trip that buys nothing.
    /// See `BlockDurability`, which is there because "completed", "ordered" and
    /// "durable" are three different claims.
    mutating func barrier() -> FSStatus {

        switch device.durability {
            case .onCompletion:
                return .ok

            // Unreachable through `mount` and `format`, which both refuse one of
            // these before the first write. Here because a guard that only
            // exists at the door is a guard the next door forgets.
            case .unknown:
                return .durabilityUnknown

            case .onFlush:
                guard device.flush() == .ok else { return deviceRefused() }
                return .ok
        }
    }


    /// A block of somebody's file, made zero.
    mutating func zeroDataBlock(_ index: UInt32) -> FSStatus {
        meta.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        return writeDataBlock(index, from: meta)
    }


    /// A block of the disk's front, made zero. For `format` and nothing else.
    mutating func zeroRawBlock(_ index: UInt32) -> FSStatus {
        meta.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))
        return writeRawBlock(index, from: meta)
    }


    // MARK: - Transactions

    /// Whether a transaction is open.
    var inTransaction: Bool { transaction.active }

    /// Whether the journal on the disk is holding nothing.
    var journalIsEmpty: Bool { journal == .empty }

    /// What the journal is holding, for the tests and for `begin`.
    var journalState: FSJournal.State { journal }

    /// How many operations were refused for wanting a seventeenth after-image.
    public var transactionOverflows: UInt32 { transaction.overflows }

    /// The refusal that will make the open transaction abort, if there is one.
    var transactionRefusal: FSStatus? { transaction.stickyFailure }


    /// Opens a transaction, which every structural change then goes into.
    ///
    /// Refused unless the journal is empty, and it is empty because the mount
    /// that opened this volume made it so: a transaction begun over another one's
    /// images would commit both.
    mutating func begin() -> FSStatus {

        guard !corrupted else { return .quarantined }
        guard !transaction.active else { return .busy }

        // Nothing on the disk depends on a `prepared` header, and this is the
        // only place it is safe to clear one. See `journal`.
        if journal == .prepared {
            guard emptyJournal(checkpoint: checkpoint) == .ok else {
                return explain(.deviceFailed)
            }
        }

        // A promise, and only a mount may finish one.
        guard journal == .empty else { return explain(.deviceFailed) }

        // Refused rather than wrapped: see `FSJournal.stamp`.
        guard transactions < UInt32.max else { return .noSpace }
        transactions += 1

        // Stamped with the mount as well as the step. See `FSJournal.stamp`.
        guard let stamp = FSJournal.stamp(
            mount: superblockGeneration, step: transactions
        ) else { return .noSpace }

        transaction.begin(generation: stamp)

        return .ok
    }


    /// Closes a transaction according to how the operation inside it went.
    ///
    /// The shape every public mutation has: open one, do the work through staged
    /// writes, and hand the answer to this. An operation that failed leaves no
    /// trace, because leaving no trace is what abandoning a transaction *is* -
    /// there is nothing to undo by hand any more.
    mutating func finish(_ status: FSStatus) -> FSStatus {

        // A staging call refused anywhere inside this transaction is a
        // transaction that cannot be committed, whatever is handed over here.
        if let refused = transaction.stickyFailure {
            abort()
            return status == .ok ? refused : status
        }

        guard status == .ok else {
            abort()
            return status
        }

        return commit()
    }


    /// Abandons a transaction. Nothing on the disk is touched.
    ///
    /// There is nothing to undo, and that is the point: the after-images are in
    /// the journal and no home block has changed, so an abandoned transaction is
    /// a disk that never heard of it. What has to be undone is a *reader's* view
    /// of it, which is why the cache goes with it.
    mutating func abort() {
        guard transaction.active else { return }

        transaction.end()
        dropCache()

        // A write that named blocks it overwrites in place may have reached some
        // of them. Settled now when the device allows it, and by `begin` if not.
        guard !unsettled.isEmpty else { return }
        if emptyJournal(checkpoint: checkpoint) != .ok { journal = .prepared }
    }


    /// The commit protocol, in the order that makes it one.
    ///
    /// Prepared, flushed, committed, flushed, applied, flushed, emptied, flushed.
    /// The two facts the order buys:
    ///
    /// - before the committed header, nothing on the disk depends on the images,
    ///   so a mount that finds `prepared` throws them away;
    /// - after it, every image will be applied, however many times the machine
    ///   restarts in the middle of applying them, because a whole-block image
    ///   written twice is a block written once.
    ///
    /// A failure after the committed header is not rolled back and must not be.
    /// The journal is left exactly as it is and the next mount finishes it.
    /// Until then a block this transaction overwrote in place reads as
    /// `damaged`: its new checksum is in the journal and not yet at home.
    mutating func commit() -> FSStatus {

        guard transaction.active else { return .ok }

        // Nothing staged is nothing to promise, and writing four headers to say
        // so would be four writes for no change.
        guard transaction.recordCount > 0 else {
            transaction.end()
            return .ok
        }

        let header = transaction.header(.committed)

        // Every image, once, and before any header names it. The barrier below
        // covers these as well as the prepared header.
        for index in 0..<transaction.recordCount {
            guard writeRawBlock(
                FSJournal.payload(of: index), from: image(index)
            ) == .ok else { return abandonPrepared() }
        }

        guard writeJournalHeader(transaction.header(.prepared)) == .ok,
              barrier() == .ok
        else { return abandonPrepared() }

        guard writeJournalHeader(header) == .ok,
              barrier() == .ok
        else { return abandonPrepared() }

        // From here the transaction exists whatever happens next, and nothing
        // short of a mount may clear it. Its images carry the checksums of every
        // block it overwrote, so nothing it named is owed a settle any more.
        journal       = .committed
        unsettled     = FSJournal.Intent()
        declaredKnown = false

        guard applyJournal(header, live: true) == .ok, barrier() == .ok else {
            transaction.end()
            return explain(.deviceFailed)
        }

        // The checkpoint goes down with the empty mark, in the same block and the
        // same write: this transaction is the newest one the home blocks hold.
        guard emptyJournal(checkpoint: header.generation) == .ok else {
            transaction.end()
            return explain(.deviceFailed)
        }

        transaction.end()
        mutations &+= 1

        return .ok
    }


    /// Gives up on a transaction that never reached its committed header.
    ///
    /// Some of the images may be on the disk and nothing points at them, so
    /// emptying the journal here is tidiness rather than a requirement: a mount
    /// that finds `prepared` discards it, and one that finds a header from before
    /// this attempt sees a state it was already going to act on. Which is why a
    /// failure to tidy up is not itself reported - what is reported is the failure
    /// that got here.
    private mutating func abandonPrepared() -> FSStatus {

        // Ended first: a settle reads the sum region, and must read what the
        // home blocks hold rather than what this transaction staged.
        transaction.end()
        dropCache()

        journal = .prepared

        // Tidied up if the device will take it, and left for `begin` to retry if
        // it will not: the failure that got here is what is reported, not this.
        let tidied = emptyJournal(checkpoint: checkpoint)
        if tidied != .ok { journal = .prepared }

        return explain(.deviceFailed)
    }


    /// Writes one journal header and nothing else, carrying the declared
    /// checksums whenever it names an overwrite.
    private mutating func writeJournalHeader(_ header: FSJournal) -> FSStatus {
        header.write(to: jrnl, declaring: declared)

        return writeRawBlock(plan.journalHeader, from: jrnl)
    }


    /// Says the journal is holding nothing, and which transaction the home blocks
    /// are up to.
    ///
    /// One write for both, because they are one fact: the journal is empty
    /// *because* everything up to `checkpoint` has been applied. A mount reads it
    /// and discards a committed earlier-mount journal, which stops one that
    /// outlived its mount going back over newer same-medium metadata. It does not
    /// make a claim about rollback of the complete storage medium.
    private mutating func emptyJournal(checkpoint: UInt64) -> FSStatus {

        // What a `prepared` header named is put right before the header goes.
        guard settle() == .ok else { return .deviceFailed }

        var header = FSJournal()
        header.generation = checkpoint

        guard writeJournalHeader(header) == .ok, barrier() == .ok else {
            return .deviceFailed
        }

        self.checkpoint = checkpoint
        journal         = .empty

        return .ok
    }


    /// Copies every after-image onto its home block.
    ///
    /// Idempotent by construction: the images are whole blocks, so applying one
    /// twice is applying it once. That is what lets a crash in the middle of this
    /// be answered by doing all of it again.
    ///
    /// `live` says where the image comes from. Finishing a commit, out of the
    /// arena, which is where staging put it; finishing somebody else's journal at
    /// mount, off the medium, because nothing in this process has ever seen it.
    /// Either way what is written is checked against the checksum the header
    /// carries, so the two sources cannot disagree without being caught.
    private mutating func applyJournal(_ header: FSJournal, live: Bool) -> FSStatus {

        for index in 0..<header.recordCount {

            if live {
                // Out of the arena, where this transaction's images have been all
                // along. No round trip, and no cache to disagree with.
                jrnl.copyMemory(from: image(index), byteCount: Int(FSLayout.blockSize))

            } else {
                guard readRawBlock(
                    FSJournal.payload(of: index), into: jrnl
                ) == .ok else { return .deviceFailed }
            }

            guard FSChecksum.over(jrnl, count: Int(FSLayout.blockSize))
                    == header.checksums[index]
            else {
                // The image about to go home is not the image the header
                // describes. Impossible by construction, so finding it means
                // something else is wrong and the home block must not have it.
                quarantine()
                return .quarantined
            }

            guard writeRawBlock(header.targets[index], from: jrnl) == .ok else {
                return .deviceFailed
            }
        }

        return .ok
    }


    /// Finishes or discards whatever the journal was holding when the power went.
    ///
    /// Called at mount and before anything is served, because what the journal
    /// holds is metadata the home blocks do not have yet.
    ///
    /// `quiet` when the journal was already empty. Anything else changed or threw
    /// away metadata after the seal was written, so the seal no longer speaks for
    /// the disk.
    private mutating func recoverJournal() -> (status: FSStatus, quiet: Bool) {
        let header: FSJournal

        switch readJournalHeader() {
            case .some(let found): header = found
            case .none           : return (corrupted ? .quarantined : .deviceFailed, false)
        }

        return (recover(header), header.state == .empty)
    }


    /// The journal header off the medium, or nil when it would not read or is
    /// not one, the second holding the volume still.
    private mutating func readJournalHeader() -> FSJournal? {

        guard readRawBlock(plan.journalHeader, into: meta) == .ok else { return nil }

        // A header that is not one is the disk contradicting itself about the
        // thing that says what to replay. There is no safe reading of it.
        guard FSJournal.isWhole(meta) else {
            quarantine()
            return nil
        }

        let header = FSJournal(reading: meta)

        guard header.targetsFit(plan) else {
            quarantine()
            return nil
        }

        return header
    }


    private mutating func recover(_ header: FSJournal) -> FSStatus {

        // Which mount wrote this, against the one opening the disk. Equal for a
        // journal the crashed mount left behind, which is what a replay is for.
        let stamped = FSJournal.mount(of: header.generation)
        let serving = superblockGeneration

        switch header.state {
            case .empty:
                // The empty mark and the checkpoint are one write, so this is
                // where the newest applied transaction is read from.
                checkpoint = header.generation
                journal    = .empty
                return .ok

            case .prepared:
                // Written and never promised. Nothing on the disk depends on
                // these images, so they go, and the checkpoint stays where the
                // last finished transaction left it. The file data it named as
                // overwritten in place is settled first, against the checksums
                // it declared when they reached the medium whole.
                checkpoint    = 0
                unsettled     = header.intent
                declaredKnown = header.declares(meta)

                if declaredKnown {
                    declared.copyMemory(
                        from     : meta.advanced(by: FSJournal.Header.declared),
                        byteCount: header.intent.blocks * 4
                    )
                }
                return emptyJournal(checkpoint: 0)

            case .committed:
                // **A committed journal from an earlier mount is stale.** Its
                // whole-block after-images would overwrite metadata written since
                // that mount, so it is discarded rather than replayed. This is
                // cross-mount stale-journal rejection on the current medium, not
                // storage anti-rollback; a whole-medium rollback is not detected.
                if stamped < serving {
                    checkpoint = header.generation
                    return emptyJournal(checkpoint: header.generation)
                }

                // Above the newest superblock, and no mount serves before
                // publishing one: the disk has lost a write it acknowledged.
                guard stamped == serving else {
                    quarantine()
                    return .quarantined
                }

                // Applying a journal must not journal what it applies.
                transaction.enter(.recovering)
                defer { transaction.serve() }

                // Every payload checked before a byte of it goes home: a payload
                // that does not check out is a transaction this cannot finish,
                // and half of one is worse than none.
                for index in 0..<header.recordCount {
                    guard readRawBlock(
                        FSJournal.payload(of: index), into: jrnl
                    ) == .ok else { return .deviceFailed }

                    guard FSChecksum.over(jrnl, count: Int(FSLayout.blockSize))
                            == header.checksums[index]
                    else {
                        quarantine()
                        return .quarantined
                    }
                }

                guard applyJournal(header, live: false) == .ok, barrier() == .ok else {
                    // Left exactly as it is, for the next mount to finish. There
                    // is nothing to roll back to.
                    return .deviceFailed
                }

                return emptyJournal(checkpoint: header.generation)
        }
    }


    // MARK: - The superblock

    /// Reads both copies and says which one this volume is mounted from.
    ///
    /// Six ways to say no, and they are six because they are six different
    /// situations. The one that matters is the difference between an empty disk
    /// and a damaged one, and with two copies it takes both of them to say
    /// "empty": a zeroed A with a live B is a disk that had something on it.
    private mutating func readSuperblocks() -> FSMount {

        guard readRawBlock(FSLayout.superblockA, into: meta) == .ok else {
            return .deviceFailed
        }

        let firstVerdict = FSSuperblock.verdict(of: meta, against: plan)
        let first = firstVerdict == .whole ? FSSuperblock(reading: meta) : nil

        guard readRawBlock(FSLayout.superblockB, into: jrnl) == .ok else {
            return .deviceFailed
        }

        let secondVerdict = FSSuperblock.verdict(of: jrnl, against: plan)
        let second = secondVerdict == .whole ? FSSuperblock(reading: jrnl) : nil

        switch FSSuperblock.choose(firstVerdict, first, secondVerdict, second) {
            case .refuse(let why):
                return why

            case .use(let block, let at):
                superblock     = block
                liveSuperblock = at
                wasDirty       = block.state != 0

                return .ok
        }
    }


    /// Writes the superblock, with a fresh generation, to the copy that is not
    /// the live one.
    ///
    /// Always the *other* copy, which is the whole of the dual-copy protocol:
    /// while this write is in flight the copy being read from is untouched, so
    /// there is no moment at which the disk has no whole superblock. Made durable
    /// before it is believed, because a generation that is only in a cache is a
    /// generation the next boot may not see.
    ///
    /// `seal` is the seal's checksum on a clean mark and zero on every other: a
    /// mounted volume is about to change, so no seal speaks for it.
    private mutating func publishSuperblock(state: UInt32, seal: UInt32 = 0) -> FSStatus {

        guard var block = superblock else { return .notFormatted }

        block.sealChecksum = state == 0 ? seal : 0

        return publishSuperblock(block, state: state)
    }


    /// Writes `block` to the copy that is not the live one, and keeps it only if
    /// that stood.
    ///
    /// The two are one step apart and the order between them is the whole point.
    /// `rename` used to put the new name in the copy this process reads *before*
    /// asking the disk to take it, so a rename whose flush failed left a machine
    /// answering to a name no disk had ever heard of - and answering to it for
    /// the rest of the boot, because nothing reads the superblock again.
    ///
    /// A failure here holds the volume still, and this is the one place where a
    /// device failure is enough on its own. Both copies are whole - that is what
    /// the dual-copy protocol buys - but which of the two the medium kept is not
    /// knowable from here: the write may have been taken and not made durable. So
    /// this process stops claiming to know what the disk is called or whether it
    /// is mounted, and stops writing to it, which is what keeps the disagreement
    /// from growing.
    private mutating func publishSuperblock(
        _ published: FSSuperblock,
        state      : UInt32
    ) -> FSStatus {

        var block = published
        guard block.generation < UInt64.max else { return .noSpace }

        let target = liveSuperblock == FSLayout.superblockA
            ? FSLayout.superblockB
            : FSLayout.superblockA

        block.generation += 1
        block.state       = state

        block.write(to: meta)

        guard writeRawBlock(target, from: meta) == .ok, barrier() == .ok else {
            // See the doc above: which copy the medium kept is not knowable from
            // here, so nothing more is claimed and nothing more is written.
            quarantine()
            return .quarantined
        }

        // Only now. Before this line the disk is the older of the two copies and
        // so is what this process says it holds.
        superblock     = block
        liveSuperblock = target

        return .ok
    }


    /// Renames the machine, through the dual-copy protocol like every other
    /// superblock change.
    mutating func rename(machine letters: UnsafeRawPointer, length: Int) -> FSStatus {

        guard let block = superblock else { return .notFormatted }

        let bytes = letters.assumingMemoryBound(to: UInt8.self)

        var renamed = block

        for index in 0..<FSLayout.machineNameLimit {
            renamed.name[index] = index < length ? bytes[index] : 0
        }

        // Handed over rather than kept: what this process answers to changes when
        // the disk has taken the change, and not a moment before.
        return publishSuperblock(renamed, state: block.state)
    }


    /// Writes an empty file system over whatever was there.
    /// Lays a fresh format down over block zero and the bookkeeping behind it.
    ///
    /// Private on purpose: reachable only through the static `format`, so there
    /// is no way to erase a disk that does not read as a deliberate act at the
    /// call site.
    private mutating func writeFreshFormat() -> FSStatus {

        // Nothing here is journalled and nothing needs to be: a format has no
        // previous state to stay coherent with, and every byte of the front of
        // the disk is about to be written by this one call. Said out loud, because
        // otherwise the staging door refuses every write below.
        transaction.enter(.formatting)
        defer { transaction.serve() }


        for block in 0..<plan.dataStart {
            let zeroed = zeroRawBlock(block)
            guard zeroed == .ok else { return zeroed }
        }

        // Everything before the data region is in use from the moment it exists.
        let claimed = setRange(start: 0, count: plan.dataStart, used: true)
        guard claimed == .ok else { return claimed }

        // The root is a container, not a folder: it is the machine itself, and
        // every block that is not the file system's own bookkeeping is its room
        // to give away.
        var root = FSObject(kind: .container, created: now)
        root.quota     = plan.totalBlocks - plan.dataStart
        root.container = FSLayout.rootObject
        root.parent    = FSLayout.rootObject

        let written = store(root, at: FSLayout.rootObject)
        guard written == .ok else { return written }

        // An empty journal, whole and checksummed, before anything can go looking
        // for one. A zeroed header is not an empty journal: it is a block that
        // has never been one, and a mount holds the volume still over it.
        guard writeJournalHeader(FSJournal()) == .ok else { return .deviceFailed }

        // Everything above reaches the medium before the superblock that says it
        // is there. The other way round is a disk that claims a file system and
        // holds half of one.
        guard barrier() == .ok else { return .deviceFailed }
        journal = .empty

        // Both copies, and the first made durable before the second is written:
        // a power cut between them leaves one whole superblock rather than two
        // halves of a change.
        var block = FSSuperblock(
            describing: plan,
            generation: 1,
            machine   : FSLayout.defaultMachineName
        )

        // Mounted, because `format` hands back a mounted volume. A clean mark
        // here would be a disk that says nobody is using it while somebody is.
        block.state = 1

        block.write(to: meta)
        guard writeRawBlock(FSLayout.superblockA, from: meta) == .ok,
              barrier() == .ok
        else { return .deviceFailed }

        block.generation = 2

        block.write(to: meta)
        guard writeRawBlock(FSLayout.superblockB, from: meta) == .ok,
              barrier() == .ok
        else { return .deviceFailed }

        superblock     = block
        liveSuperblock = FSLayout.superblockB
        wasDirty       = false
        containerCount = 1

        // Every bitmap and table block was just written by this process, so its
        // checksum is known from here on.
        sumsKnown      = true

        return .ok
    }


    /// The machine's own name, written into `destination`, which must hold
    /// `FSLayout.machineNameLimit` bytes. Answers how long it is.
    ///
    /// Out of the superblock this volume was mounted from, which is in memory: a
    /// read of the disk here would be a read of a block whose newer copy is the
    /// other one.
    public func machineName(into destination: UnsafeMutableRawPointer) -> Int {

        guard let block = superblock else { return 0 }

        let out = destination.assumingMemoryBound(to: UInt8.self)

        var length = 0
        while length < FSLayout.machineNameLimit,
              block.name[length] > 0x20, block.name[length] < 0x7F {

            out[length] = block.name[length]
            length += 1
        }

        return length
    }


    // MARK: - For the extensions

    var metaBuffer: UnsafeMutableRawPointer { meta }
    var dataBuffer: UnsafeMutableRawPointer { data }
    var tallyBuffer: UnsafeMutableRawPointer { tally }
    var targetBuffer: UnsafeMutableRawPointer { targets }
    var scrubBuffer: UnsafeMutableRawPointer { scrub }
    var declaredBuffer: UnsafeMutableRawPointer { declared }

    /// The journal's arena, which a scan borrows outside a transaction.
    var arenaBuffer: UnsafeMutableRawPointer { images }

    /// The superblock's `state` word, for a change that must not disturb it.
    var mountedMark: UInt32 { superblock?.state ?? 0 }

    /// The seal checksum the superblock this volume was read from names: zero
    /// unless that copy says the volume was shut down cleanly and sealed.
    var namedSeal: UInt32 {
        guard let block = superblock, block.state == 0 else { return 0 }
        return block.sealChecksum
    }

    /// Which write of the superblock this volume is reading. Bumped by every
    /// mount, unmount and rename, so it separates two mounts of one disk.
    var superblockGeneration: UInt64 { superblock?.generation ?? 0 }
}
