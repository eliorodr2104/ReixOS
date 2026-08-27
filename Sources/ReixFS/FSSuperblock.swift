//
//  FSSuperblock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// One copy of the front of the disk.
///
/// A value read out of a block rather than a set of offsets poked at in place,
/// because the questions worth asking about it are questions about the whole of
/// it: does it check out, does it describe this disk, and is it newer than the
/// other one. All three can then be asked on a host with no disk at all.
///
/// There are two copies on purpose. One is always the last one that was written
/// completely, so a power cut in the middle of an update costs the newer copy and
/// not the disk: the older one is still there, still checks out, and still says
/// where everything is.
struct FSSuperblock {

    /// What is written into `FSSuperblockField.commit` when a superblock is complete.
    ///
    /// `RXSB`, so a hex dump says it. Its job is narrow and worth stating: it
    /// rejects a block that was never a superblock, cheaply and before the
    /// checksum is computed. What catches a superblock torn half way through an
    /// update is the checksum, because both halves of a torn write carry this.
    static let completeMarker: UInt32 = 0x5253_4258      // "RXSB" little-endian

    /// Where the write counter sits in a superblock block, for a test that has to
    /// damage one from the outside. Named rather than a literal seventy-two.
    static var generationOffset: Int { FSSuperblockField.generation }

    var magic       : UInt64
    var blockSize   : UInt32
    var totalBlocks : UInt32
    var bitmapStart : UInt32
    var bitmapBlocks: UInt32
    var tableStart  : UInt32
    var tableBlocks : UInt32
    var dataStart   : UInt32
    var objectCount : UInt32
    var rootObject  : UInt32

    /// Non-zero while the volume is mounted, so the next mount can tell an
    /// orderly shutdown from a power cut.
    var state: UInt32

    var name: InlineArray<24, UInt8>

    var generation  : UInt64
    var journalStart : UInt32
    var journalBlocks: UInt32


    /// A fresh superblock for `plan`, named `machine`.
    init(describing plan: FSLayout.Plan, generation: UInt64, machine: StaticString) {
        self.magic        = FSLayout.magic
        self.blockSize    = UInt32(FSLayout.blockSize)
        self.totalBlocks  = plan.totalBlocks
        self.bitmapStart  = plan.bitmapStart
        self.bitmapBlocks = plan.bitmapBlocks
        self.tableStart   = plan.tableStart
        self.tableBlocks  = plan.tableBlocks
        self.dataStart    = plan.dataStart
        self.objectCount  = plan.objectCount
        self.rootObject   = FSLayout.rootObject
        self.state        = 0
        self.generation   = generation
        self.journalStart  = plan.journalStart
        self.journalBlocks = plan.journalBlocks

        var letters = InlineArray<24, UInt8>(repeating: 0)
        for index in 0..<min(machine.utf8CodeUnitCount, FSLayout.machineNameLimit) {
            letters[index] = machine.utf8Start[index]
        }
        self.name = letters
    }


    /// The fields as they stand in `base`. No judgement: `reading` is bytes in,
    /// fields out, and `verdict` is where they are asked whether they add up.
    init(reading base: UnsafeRawPointer) {
        self.magic        = base.loadUnaligned(fromByteOffset: FSSuperblockField.magic,       as: UInt64.self)
        self.blockSize    = base.loadUnaligned(fromByteOffset: FSSuperblockField.blockSize,   as: UInt32.self)
        self.totalBlocks  = base.loadUnaligned(fromByteOffset: FSSuperblockField.totalBlocks, as: UInt32.self)
        self.bitmapStart  = base.loadUnaligned(fromByteOffset: FSSuperblockField.bitmapStart, as: UInt32.self)
        self.bitmapBlocks = base.loadUnaligned(fromByteOffset: FSSuperblockField.bitmapCount, as: UInt32.self)
        self.tableStart   = base.loadUnaligned(fromByteOffset: FSSuperblockField.tableStart,  as: UInt32.self)
        self.tableBlocks  = base.loadUnaligned(fromByteOffset: FSSuperblockField.tableCount,  as: UInt32.self)
        self.dataStart    = base.loadUnaligned(fromByteOffset: FSSuperblockField.dataStart,   as: UInt32.self)
        self.objectCount  = base.loadUnaligned(fromByteOffset: FSSuperblockField.objectCount, as: UInt32.self)
        self.rootObject   = base.loadUnaligned(fromByteOffset: FSSuperblockField.rootObject,  as: UInt32.self)
        self.state        = base.loadUnaligned(fromByteOffset: FSSuperblockField.state,       as: UInt32.self)
        self.generation   = base.loadUnaligned(fromByteOffset: FSSuperblockField.generation,  as: UInt64.self)
        self.journalStart  = base.loadUnaligned(fromByteOffset: FSSuperblockField.journalStart,  as: UInt32.self)
        self.journalBlocks = base.loadUnaligned(fromByteOffset: FSSuperblockField.journalBlocks, as: UInt32.self)

        var letters = InlineArray<24, UInt8>(repeating: 0)
        let bytes = base.advanced(by: FSSuperblockField.name).assumingMemoryBound(to: UInt8.self)
        for index in 0..<FSLayout.machineNameLimit { letters[index] = bytes[index] }
        self.name = letters
    }


    /// Lays this superblock over a whole block, marker and checksum last.
    ///
    /// The block is zeroed first, so two writes of the same superblock produce
    /// the same bytes and a checksum means what it says.
    func write(to base: UnsafeMutableRawPointer) {

        base.initializeMemory(as: UInt8.self, repeating: 0, count: Int(FSLayout.blockSize))

        base.storeBytes(of: magic,        toByteOffset: FSSuperblockField.magic,       as: UInt64.self)
        base.storeBytes(of: blockSize,    toByteOffset: FSSuperblockField.blockSize,   as: UInt32.self)
        base.storeBytes(of: totalBlocks,  toByteOffset: FSSuperblockField.totalBlocks, as: UInt32.self)
        base.storeBytes(of: bitmapStart,  toByteOffset: FSSuperblockField.bitmapStart, as: UInt32.self)
        base.storeBytes(of: bitmapBlocks, toByteOffset: FSSuperblockField.bitmapCount, as: UInt32.self)
        base.storeBytes(of: tableStart,   toByteOffset: FSSuperblockField.tableStart,  as: UInt32.self)
        base.storeBytes(of: tableBlocks,  toByteOffset: FSSuperblockField.tableCount,  as: UInt32.self)
        base.storeBytes(of: dataStart,    toByteOffset: FSSuperblockField.dataStart,   as: UInt32.self)
        base.storeBytes(of: objectCount,  toByteOffset: FSSuperblockField.objectCount, as: UInt32.self)
        base.storeBytes(of: rootObject,   toByteOffset: FSSuperblockField.rootObject,  as: UInt32.self)
        base.storeBytes(of: state,        toByteOffset: FSSuperblockField.state,       as: UInt32.self)
        base.storeBytes(of: generation,   toByteOffset: FSSuperblockField.generation,  as: UInt64.self)
        base.storeBytes(of: journalStart,  toByteOffset: FSSuperblockField.journalStart,  as: UInt32.self)
        base.storeBytes(of: journalBlocks, toByteOffset: FSSuperblockField.journalBlocks, as: UInt32.self)

        let letters = base.advanced(by: FSSuperblockField.name).assumingMemoryBound(to: UInt8.self)
        for index in 0..<FSLayout.machineNameLimit { letters[index] = name[index] }

        base.storeBytes(of: Self.completeMarker, toByteOffset: FSSuperblockField.commit, as: UInt32.self)

        base.storeBytes(
            of          : FSChecksum.over(base, count: FSSuperblockField.width, zeroing: FSSuperblockField.checksum),
            toByteOffset: FSSuperblockField.checksum,
            as          : UInt32.self
        )
    }


    /// Whether this describes the disk `plan` was worked out for.
    ///
    /// The layout is a calculation, so a superblock that disagrees with it
    /// describes a disk this is not: a torn write, a bad block, or an image that
    /// was resized underneath its own superblock.
    func describes(_ plan: FSLayout.Plan) -> Bool {
        blockSize     == UInt32(FSLayout.blockSize)
            && totalBlocks  == plan.totalBlocks
            && bitmapStart  == plan.bitmapStart
            && bitmapBlocks == plan.bitmapBlocks
            && tableStart   == plan.tableStart
            && tableBlocks  == plan.tableBlocks
            && dataStart    == plan.dataStart
            && objectCount  == plan.objectCount
            && rootObject   == FSLayout.rootObject
            && journalStart  == plan.journalStart
            && journalBlocks == plan.journalBlocks
    }


    // MARK: - What one copy is

    /// What a block holding a superblock turned out to be.
    enum Verdict: Equatable {

        /// A whole superblock of this format, describing this disk.
        case whole

        /// Every byte of the block is zero.
        case blank

        /// This format, in a version this build does not know how to read.
        case unsupported(UInt16)

        /// Anything else: not this format, torn, or describing another disk.
        case corrupt
    }


    /// What is in `base`, judged against `plan`.
    static func verdict(
        of  base: UnsafeRawPointer,
        against plan: FSLayout.Plan
    ) -> Verdict {

        // Blank is the whole block, not the magic. A superblock whose magic was
        // lost half way through a write still has every other field, and calling
        // that an empty disk is how a torn write became an erase.
        if FSChecksum.isZero(base, count: Int(FSLayout.blockSize)) { return .blank }

        let parts = FSLayout.magicParts(
            base.loadUnaligned(fromByteOffset: FSSuperblockField.magic, as: UInt64.self)
        )

        // Not our format at all: somebody else's disk, or one damaged past
        // recognising. Either way not ours to write.
        guard parts.family == FSLayout.magicFamily else { return .corrupt }

        // Ours, in a version this build does not know. Named, so that an older
        // machine meeting a newer disk says so instead of treating an unfamiliar
        // number as an empty disk. Said before the checksum, because a version
        // this build cannot read may not compute its checksum the same way.
        guard parts.version == FSLayout.formatVersion else {
            return .unsupported(parts.version)
        }

        guard base.loadUnaligned(fromByteOffset: FSSuperblockField.commit, as: UInt32.self)
                == Self.completeMarker
        else { return .corrupt }

        let stored = base.loadUnaligned(fromByteOffset: FSSuperblockField.checksum, as: UInt32.self)
        guard stored == FSChecksum.over(base, count: FSSuperblockField.width, zeroing: FSSuperblockField.checksum)
        else { return .corrupt }

        guard FSSuperblock(reading: base).describes(plan) else { return .corrupt }

        return .whole
    }


    // MARK: - Which of the two

    /// Which copy to mount, or why neither.
    enum Choice {

        /// Mount this one, from this block. The other copy is rebuilt by the
        /// next update either way, because an update always writes the copy it
        /// is not reading from - so there is nothing to say here about whether
        /// the other one was usable.
        case use(FSSuperblock, at: UInt32)

        case refuse(FSMount)
    }


    /// Picks between the two copies.
    ///
    /// The newer of two whole ones, because generation is bumped on every write
    /// of either and the newer is by definition the one that was finished last.
    /// One whole one is enough to mount from, and the other is rebuilt by the
    /// next update rather than repaired on the spot: repairing it would be a
    /// write before the volume has been recognised.
    static func choose(
        _ a: Verdict, _ aBlock: FSSuperblock?,
        _ b: Verdict, _ bBlock: FSSuperblock?
    ) -> Choice {

        switch (a, b) {
            case (.whole, .whole):
                guard let first = aBlock, let second = bBlock else {
                    return .refuse(.corrupt)
                }

                return first.generation >= second.generation
                    ? .use(first,  at: FSLayout.superblockA)
                    : .use(second, at: FSLayout.superblockB)

            case (.whole, _):
                guard let first = aBlock else { return .refuse(.corrupt) }
                return .use(first, at: FSLayout.superblockA)

            case (_, .whole):
                guard let second = bBlock else { return .refuse(.corrupt) }
                return .use(second, at: FSLayout.superblockB)

            // Neither is usable. An empty disk is the only one anybody should be
            // willing to write over, and it is empty only if *both* copies are:
            // a zeroed A with a wrecked B is a disk that had something on it.
            case (.blank, .blank):
                return .refuse(.blank)

            // A version this build cannot read, said by name, and said before
            // corruption: an older machine meeting a newer disk should be told
            // what it met.
            case (.unsupported(let version), _):
                return .refuse(.unsupportedVersion(version))

            case (_, .unsupported(let version)):
                return .refuse(.unsupportedVersion(version))

            default:
                return .refuse(.corrupt)
        }
    }
}
