//
//  ELFLoaderFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.


@testable import Kernel

/// One PT_LOAD segment of a fixture image. `flags` is the ELF `p_flags`
/// bitmask: 0x4 read, 0x2 write, 0x1 execute.
public struct ELFSegmentFixture {
    public let flags     : UInt32
    public let virtual   : UInt64
    public let memorySize: UInt64
    public let payload   : [UInt8]

    /// Bytes written after `payload` and left out of `p_filesz`, so a fixture can
    /// say what the file holds between the end of the segment's bytes and the end
    /// of the page they finish in.
    ///
    /// That range is the one `ImageSharing` scans before it shares a tail page:
    /// zeros are the linker's own padding and make the page shareable, anything
    /// else is a page the loader has to copy instead.
    public let trailing  : [UInt8]

    public init(
        flags     : UInt32,
        virtual   : UInt64,
        memorySize: UInt64,
        payload   : [UInt8] = [],
        trailing  : [UInt8] = []
    ) {
        self.flags      = flags
        self.virtual    = virtual
        self.memorySize = memorySize
        self.payload    = payload
        self.trailing   = trailing
    }
}


/// How a fixture image and its archive are laid out, which is what decides
/// whether `ImageSharing` can share anything out of them.
///
/// Three independent conditions, one field each, so a test can fail exactly one
/// of them and leave the others satisfied. `p_vaddr`, the fourth, is a property
/// of a single segment and belongs on `ELFSegmentFixture.virtual`.
public struct ELFFixtureLayout {

    /// Alignment of every segment's payload inside the image, and therefore of
    /// `p_offset`.
    public let payloadAlignment: Int

    /// True to interleave `@pad` members so each real member's data starts on a
    /// page boundary, the layout `UstarWriter` gives the real initrd.
    public let pageAlignedMembers: Bool

    /// Bytes the archive is nudged past the page boundary its storage begins on,
    /// which moves the resident base off a page without touching anything else.
    public let baseShift: Int

    public init(
        payloadAlignment  : Int,
        pageAlignedMembers: Bool,
        baseShift         : Int
    ) {
        self.payloadAlignment   = payloadAlignment
        self.pageAlignedMembers = pageAlignedMembers
        self.baseShift          = baseShift
    }

    /// What every fixture was staged as before page sharing existed: 16-byte
    /// payload offsets in a plain single-member archive, whose member data sits
    /// 512 bytes into the archive.
    ///
    /// Nothing about it is page aligned, so the loader copies every page and the
    /// W^X fixtures keep observing the staged page manager's refusal.
    public static let unaligned = ELFFixtureLayout(
        payloadAlignment  : 16,
        pageAlignedMembers: false,
        baseShift         : 0
    )

    /// The real initrd's shape: page-aligned payloads inside the image, `@pad`ded
    /// members, and the archive on a page boundary.
    public static let shareable = ELFFixtureLayout(
        payloadAlignment  : 4096,
        pageAlignedMembers: true,
        baseShift         : 0
    )

    /// `shareable` with `p_offset` alone unaligned.
    public static let unalignedOffsets = ELFFixtureLayout(
        payloadAlignment  : 16,
        pageAlignedMembers: true,
        baseShift         : 0
    )

    /// `shareable` with the resident base alone unaligned.
    public static let unalignedBase = ELFFixtureLayout(
        payloadAlignment  : 4096,
        pageAlignedMembers: true,
        baseShift         : 16
    )
}


/// What one `loadSegments` run over a fixture did.
public struct ELFLoadOutcome {

    /// The loader's verdict, `.failure` carrying the diagnosis it threw.
    public let result: Result<LoadedELF, ElfError>

    /// True when the VMA manager came back byte for byte as it was handed over,
    /// meaning no region was registered and no bookkeeping moved.
    public let vmaManagerUntouched: Bool

    /// Frames the physical page manager handed out.
    public let allocatedFrames: UInt64

    /// Non-zero descriptors in the root translation table, i.e. published PTEs.
    public let publishedDescriptors: Int
}


/// Builds a fixture image, wraps it in a tar the real `TarFileSystem` can open,
/// and runs the real loader over it.
///
/// `nil` means the fixture itself could not be staged (the archive did not open),
/// which is a broken test rather than a loader verdict.
///
/// ## What is real here and what is staged
///
/// Real: `ElfParser`, `TarFileSystem`, `ImageSharing`, `VMAManager`,
/// `BucketsHeap`, `UserSpaceLayout`, `AddressSpace`, and the header layouts the
/// parser reads. Staged: the physical page manager, left zeroed on purpose, and
/// the virtual memory manager, which the paths exercised here never reach.
///
/// A zeroed manager has a nil `framesMetadata`, so `alloc` refuses before touching
/// anything and the refusal travels the kernel's own error path: the heap returns
/// nil, `registerRegion` throws `.heapAllocationFailed`, the loader reports
/// `.allocationFailed`.
///
/// That is what makes an accept-path fixture usable as a positive control. A
/// layout the W^X gate lets through reaches the mutating pass and comes back
/// `.allocationFailed`; a layout the gate rejects comes back
/// `.writeExecuteConflict` from before any collaborator was called. The two
/// verdicts are only distinguishable if the gate runs where it claims to.
///
/// The same refusal is what stops this entry point from observing the mapping
/// pass itself: the first `registerRegion` of the pass fails, whether the region
/// was going to be shared or copied. `withStagedELFImage` asks what the sharing
/// gate decided, and `withLoadedELFImage` runs the pass with a live page manager
/// behind it and hands back the address space.
public func loadELFFixture(
    _ segments  : [ELFSegmentFixture],
    named name  : String = "elf",
    layout      : ELFFixtureLayout = .unaligned
) -> ELFLoadOutcome? {

    var outcome: ELFLoadOutcome?

    withStagedArchive(
        makeFixtureArchive(segments, named: name, layout: layout),
        baseShift: layout.baseShift
    ) { _, _ in

        let fileSystem = UnsafeMutablePointer<KernelInternalFileSystem>.allocate(capacity: 1)
        fileSystem.initialize(to: TarFileSystem())
        defer {
            fileSystem.deinitialize(count: 1)
            fileSystem.deallocate()
        }

        guard case .success(let handle) = fileSystem.pointee.open(path: name, flags: [.read]) else {
            return
        }

        let rootTable = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
        rootTable.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
        defer { rootTable.deallocate() }

        let ppm = allocateZeroed(KernelPPM.self)
        let vmm = allocateZeroed(VirtualMemoryManager.self)
        defer {
            UnsafeMutableRawPointer(vmm).deallocate()
            UnsafeMutableRawPointer(ppm).deallocate()
        }

        let heap = UnsafeMutablePointer<KernelHeap>.allocate(capacity: 1)
        heap.initialize(to: KernelHeap(ppmPtr: ppm))
        defer {
            heap.deinitialize(count: 1)
            heap.deallocate()
        }

        let rootPhysical = PhysicalAddress(UInt(bitPattern: rootTable))

        let vmaManager = UnsafeMutablePointer<VMAManager>.allocate(capacity: 1)
        vmaManager.initialize(to: VMAManager(
            heap             : heap,
            vmm              : vmm,
            ppm              : ppm,
            rootTablePhysical: rootPhysical
        ))
        defer {
            vmaManager.deinitialize(count: 1)
            vmaManager.deallocate()
        }

        let baseline     = rawBytes(of: vmaManager)
        let addressSpace = AddressSpace(
            rootTablePhysical: rootPhysical,
            asid             : 0,
            vmaManager       : vmaManager
        )

        // Read before the outcome is composed, so the comparison below is against
        // the manager as the loader left it.
        let result = loadResult(
            handle      : handle,
            fileSystem  : fileSystem,
            addressSpace: addressSpace,
            vmaManager  : vmaManager,
            vmm         : vmm,
            ppm         : ppm
        )

        outcome = ELFLoadOutcome(
            result              : result,
            vmaManagerUntouched : rawBytes(of: vmaManager) == baseline,
            allocatedFrames     : ppm.pointee.allocatedPages,
            publishedDescriptors: nonZeroDescriptors(in: rootTable)
        )
    }

    return outcome
}


/// One `loadSegments` call as a `Result`.
///
/// A function of its own because the call is made from inside a closure, where a
/// `catch` no longer infers the typed `ElfError` and lands on `any Error`.
private func loadResult(
    handle      : FileHandle,
    fileSystem  : UnsafeMutablePointer<KernelInternalFileSystem>,
    addressSpace: borrowing AddressSpace,
    vmaManager  : UnsafeMutablePointer<VMAManager>,
    vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
    ppm         : UnsafeMutablePointer<KernelPPM>
) -> Result<LoadedELF, ElfError> {

    do {
        return .success(try ElfParser.loadSegments(
            handle      : handle,
            fileSystem  : fileSystem,
            addressSpace: addressSpace,
            vmaManager  : vmaManager,
            vmm         : vmm,
            ppm         : ppm
        ))

    } catch { return .failure(error) }
}


// MARK: - The sharing gate on its own

/// A fixture archive parked in `Kernel.platformInfo`, together with what the real
/// `TarFileSystem` reports about its ELF member.
///
/// Everything the sharing gate is asked about comes from the same place the boot
/// path gets it from: `residentBase` and `fileSize` are the filesystem's answers
/// for an open handle, the segment headers are read back out of the staged bytes,
/// and the initrd window is the one the archive was staged in.
public struct StagedELFImage {

    /// Address the filesystem hands out for the member's data, which is what the
    /// loader passes as `residentBase`.
    public let residentBase: PhysicalAddress

    /// Size of the archive member, the bound the tail scan may not read past.
    public let fileSize: UInt64

    public let initrdStart: PhysicalAddress
    public let initrdEnd  : PhysicalAddress

    /// The image's PT_LOAD headers, in the order the loader collects them.
    let segments: [Elf64_Phdr_t]

    public var segmentCount: Int { segments.count }


    /// `ImageSharing`'s verdict for segment `index`: how many of its leading pages
    /// the loader may map straight out of the archive.
    ///
    /// Call it once per segment per test when the test also reads
    /// `ImageSharing.declinedTailPages`: a refused tail bumps that counter, so a
    /// second call would count the same refusal twice.
    public func shareablePages(of index: Int) -> UInt64 {
        var table = InlineArray<16, Elf64_Phdr_t>(repeating: Elf64_Phdr_t())

        let count = min(segments.count, table.count)
        for i in 0..<count { table[i] = segments[i] }

        return ImageSharing.shareablePageCount(
            of          : index,
            in          : table.span,
            count       : count,
            residentBase: residentBase,
            fileSize    : fileSize
        )
    }


    /// Pages segment `index` covers in the address space. The ones
    /// `shareablePages` cleared come from the archive, the rest from frames of
    /// this address space's own.
    public func pageCount(of index: Int) -> UInt64 {
        guard let range = UserSpaceLayout.checkedPageRange(
            address: segments[index].p_vaddr,
            size   : segments[index].p_memsz
        ) else { return 0 }

        return (range.end - range.start) / UserSpaceLayout.pageSize
    }


    /// `p_offset` of segment `index`, the offset inside the member the shared run
    /// starts at.
    public func fileOffset(of index: Int) -> UInt64 {
        segments[index].p_offset
    }


    /// The frames `ElfParser` aliases for the first `count` pages of segment
    /// `index`, derived the way the loader derives them.
    ///
    /// Mirrored arithmetic and not an observation: the mapping pass cannot run on
    /// a host process, so this is here to be bounded against the archive rather
    /// than to prove a PTE was written.
    public func aliasedPages(of index: Int, count: UInt64) -> [PhysicalAddress] {
        let offset = segments[index].p_offset

        return (0..<count).map {
            residentBase + offset + $0 * UserSpaceLayout.pageSize
        }
    }


    /// True when `[from, to)` of the member holds a byte that is not zero.
    ///
    /// Offsets are member-relative, like `p_offset`, and may run past `fileSize`:
    /// that is the point, since a range past the member is what a shared tail page
    /// would have published. Bounded to the staged window, so a range past the
    /// archive answers false instead of reading memory the fixture does not own.
    public func hasNonZeroByte(from: UInt64, to: UInt64) -> Bool {
        guard to > from, residentBase + to <= initrdEnd else { return false }
        guard let base = UnsafeRawPointer(bitPattern: UInt(residentBase)) else {
            return false
        }

        var cursor = from
        while cursor < to {
            if base.load(fromByteOffset: Int(cursor), as: UInt8.self) != 0 {
                return true
            }

            cursor += 1
        }

        return false
    }


    /// Moves the end of the staged initrd window, for the tests whose subject is
    /// that bound. The whole window is restored when the fixture returns.
    public func stageInitrdEnd(_ end: PhysicalAddress) {
        Kernel.platformInfo.initrdEnd = end
    }
}


/// Stages a fixture archive, opens its ELF member with the real `TarFileSystem`,
/// and runs `body` over what the sharing gate would be asked about.
///
/// Returns false when the archive did not open, which is a broken fixture rather
/// than a verdict. Nothing here runs the loader: `loadELFFixture` does that, and
/// says why it cannot see past the first `registerRegion`.
///
/// - Parameter followedBy: bytes of a second archive member placed after the
///   image, standing in for the neighbour a tail page must never publish.
@discardableResult
public func withStagedELFImage(
    _ segments     : [ELFSegmentFixture],
    named name     : String = "elf",
    layout         : ELFFixtureLayout = .shareable,
    followedBy next: [UInt8]? = nil,
    _ body         : (StagedELFImage) -> Void
) -> Bool {

    var opened = false

    withStagedArchive(
        makeFixtureArchive(segments, named: name, layout: layout, followedBy: next),
        baseShift: layout.baseShift
    ) { start, end in

        let fileSystem = UnsafeMutablePointer<KernelInternalFileSystem>.allocate(capacity: 1)
        fileSystem.initialize(to: TarFileSystem())
        defer {
            fileSystem.deinitialize(count: 1)
            fileSystem.deallocate()
        }

        guard case .success(let handle) = fileSystem.pointee.open(path: name, flags: [.read]),
              let residentBase = fileSystem.pointee.residentBase(handle: handle),
              case .success(let size) = fileSystem.pointee.seek(
                  handle: handle,
                  to    : 0,
                  method: .end
              ), size >= 0
        else { return }

        opened = true

        body(StagedELFImage(
            residentBase: residentBase,
            fileSize    : UInt64(size),
            initrdStart : start,
            initrdEnd   : end,
            segments    : readProgramHeaders(at: residentBase)
        ))
    }

    return opened
}


// MARK: - The loader over a live page manager

/// One region the loader registered, snapshotted so the assertions outlive the
/// heap cell the VMA lived in.
public struct ELFRegion {
    public let start      : VirtualAddress
    public let end        : VirtualAddress
    public let backing    : BackingType
    public let permissions: VMAPermissions

    public var pages: UInt64 { (end - start) / UserSpaceLayout.pageSize }
}


/// An address space the real loader built, with the archive it was loaded from
/// still staged and the page tables still readable.
public struct LoadedELFImage {

    public let result: Result<LoadedELF, ElfError>

    /// The VMAs the loader registered, in address order.
    public let regions: [ELFRegion]

    public let residentBase: PhysicalAddress
    public let fileSize    : UInt64
    public let initrdStart : PhysicalAddress
    public let initrdEnd   : PhysicalAddress

    /// The arena the physical page manager hands frames out of, which is where a
    /// page this address space owns has to come from.
    public let arenaStart: PhysicalAddress
    public let arenaEnd  : PhysicalAddress

    /// The image's PT_LOAD headers, read back out of the staged bytes.
    let segments : [Elf64_Phdr_t]
    let vmm      : UnsafeMutablePointer<VirtualMemoryManager>
    let rootTable: PhysicalAddress


    /// `p_offset` of segment `index`, the offset inside the member an aliased run
    /// starts at.
    public func fileOffset(of index: Int) -> UInt64 {
        segments[index].p_offset
    }


    /// What the page tables the loader wrote resolve `virtual` to.
    public func translate(_ virtual: VirtualAddress) -> PhysicalAddress? {
        vmm.pointee.physicalAddressOf(rootTable: rootTable, virtual: virtual)
    }


    /// True when `physical` is a byte of the staged archive, i.e. an initrd frame
    /// the loader aliased instead of copying.
    public func isInsideArchive(_ physical: PhysicalAddress) -> Bool {
        physical >= initrdStart && physical < initrdEnd
    }


    /// True when `physical` is a frame of the arena, i.e. one this address space
    /// was given and owns.
    public func isPrivateFrame(_ physical: PhysicalAddress) -> Bool {
        physical >= arenaStart && physical < arenaEnd
    }


    /// The byte a process running in this address space would read at `virtual`,
    /// resolved through the loader's own translations.
    public func byte(at virtual: VirtualAddress) -> UInt8? {
        let pageSize = UserSpaceLayout.pageSize

        guard let physical = translate(virtual & ~(pageSize - 1)),
              let page     = UnsafeRawPointer(bitPattern: UInt(physical))
        else { return nil }

        return page.load(
            fromByteOffset: Int(virtual & (pageSize - 1)),
            as            : UInt8.self
        )
    }
}


/// Runs the real loader with a live physical page manager and kernel heap behind
/// it, then hands `body` the address space it built.
///
/// Returns false when the archive did not open. Everything the loader touches is
/// real here: the heap allocates VMA nodes out of a host arena, the page manager
/// hands out frames of it, and the page tables are written by the VMM's own
/// walker, so the mapping pass can be read back page by page.
///
/// Two host seams make that possible, both gated on `!hasFeature(Embedded)` and
/// therefore absent from the machine: the `PhysicalPageManager` initialiser
/// `HostRAM.installLiveManager` uses, and `PPMBackend.physicalOffset`, which is
/// set to zero because over a host arena a frame's physical address is already a
/// pointer this process owns.
///
/// The one thing the fixture has to do for the VMM is build the levels above L3:
/// `mapTable` allocates a missing level from the manager the staged VMM does not
/// carry a pointer to. A scratch page in each 2 MiB span the image covers is
/// enough, and it is the last page of the span so no fixture segment can reach it.
@discardableResult
public func withLoadedELFImage(
    _ segments: [ELFSegmentFixture],
    named name: String = "elf",
    layout    : ELFFixtureLayout = .shareable,
    arenaPages: Int = 64,
    _ body    : (LoadedELFImage) -> Void
) -> Bool {
  withKernelTestGlobals {

    var opened = false

    withStagedArchive(
        makeFixtureArchive(segments, named: name, layout: layout),
        baseShift: layout.baseShift
    ) { start, end in

        let fileSystem = UnsafeMutablePointer<KernelInternalFileSystem>.allocate(capacity: 1)
        fileSystem.initialize(to: TarFileSystem())
        defer {
            fileSystem.deinitialize(count: 1)
            fileSystem.deallocate()
        }

        guard case .success(let handle) = fileSystem.pointee.open(path: name, flags: [.read]),
              let residentBase = fileSystem.pointee.residentBase(handle: handle),
              case .success(let size) = fileSystem.pointee.seek(
                  handle: handle,
                  to    : 0,
                  method: .end
              ), size >= 0
        else { return }

        opened = true

        let ram = HostRAM(pages: arenaPages)
        defer { ram.release() }

        ram.installLiveManager()
        _ = ram.donateAll()

        let savedOffset = PPMBackend.physicalOffset
        PPMBackend.physicalOffset = 0
        defer { PPMBackend.physicalOffset = savedOffset }

        let heap = UnsafeMutablePointer<KernelHeap>.allocate(capacity: 1)
        heap.initialize(to: KernelHeap(ppmPtr: ram.ppm))
        defer {
            heap.deinitialize(count: 1)
            heap.deallocate()
        }

        let vmaManager = UnsafeMutablePointer<VMAManager>.allocate(capacity: 1)
        vmaManager.initialize(to: VMAManager(
            heap             : heap,
            vmm              : ram.vmm,
            ppm              : ram.ppm,
            rootTablePhysical: ram.rootTablePhysical
        ))
        defer {
            vmaManager.deinitialize(count: 1)
            vmaManager.deallocate()
        }

        buildTableLevels(in: ram, for: segments)

        let addressSpace = AddressSpace(
            rootTablePhysical: ram.rootTablePhysical,
            asid             : 0,
            vmaManager       : vmaManager
        )

        let result = loadResult(
            handle      : handle,
            fileSystem  : fileSystem,
            addressSpace: addressSpace,
            vmaManager  : vmaManager,
            vmm         : ram.vmm,
            ppm         : ram.ppm
        )

        body(LoadedELFImage(
            result      : result,
            regions     : registeredRegions(of: vmaManager),
            residentBase: residentBase,
            fileSize    : UInt64(size),
            initrdStart : start,
            initrdEnd   : end,
            arenaStart  : ram.base,
            arenaEnd    : ram.end,
            segments    : readProgramHeaders(at: residentBase),
            vmm         : ram.vmm,
            rootTable   : ram.rootTablePhysical
        ))

        // The VMA nodes are heap cells inside the arena, which `ram.release()`
        // frees wholesale, so nothing here has to unlink them first.
    }

    return opened
  }
}


/// Installs one scratch mapping in every 2 MiB span the image covers, so the
/// loader's own `mapUserPage` finds every level above L3 already present.
private func buildTableLevels(
    in  ram     : HostRAM,
    for segments: [ELFSegmentFixture]
) {
    let span: UInt64 = 2 * 1024 * 1024
    var covered: [VirtualAddress] = []

    for segment in segments {
        guard let range = UserSpaceLayout.checkedPageRange(
            address: segment.virtual,
            size   : segment.memorySize
        ) else { continue }

        var base = range.start & ~(span - 1)
        while base < range.end {
            defer { base += span }

            guard !covered.contains(base) else { continue }
            covered.append(base)

            ram.mapPage(
                virtual : base + span - UserSpaceLayout.pageSize,
                physical: ram.base
            )
        }
    }
}


private func registeredRegions(
    of manager: UnsafeMutablePointer<VMAManager>
) -> [ELFRegion] {

    var result : [ELFRegion] = []
    var current = manager.pointee.vmaList.head

    while let node = current {
        result.append(ELFRegion(
            start      : node.pointee.startAddress,
            end        : node.pointee.endAddress,
            backing    : node.pointee.backingType,
            permissions: node.pointee.permissions
        ))

        current = node.pointee.next
    }

    return result
}


// MARK: - Image and archive builders

/// Serialises `segments` into an ELF64 AArch64 executable.
///
/// The headers are written through the parser's own `Elf64_*_t` structs, so the
/// suite asserts their sizes separately: a layout that drifted from the on-disk
/// format would otherwise drift in fixture and parser together and stay hidden.
///
/// - Parameter payloadAlignment: alignment of every `p_offset`. 4096 is what the
///   real toolchain produces and the only value `ImageSharing` can share from.
public func makeELFImage(
    _ segments      : [ELFSegmentFixture],
    payloadAlignment: Int = 16
) -> [UInt8] {
    let headerSize        = MemoryLayout<Elf64_Ehdr_t>.size
    let programHeaderSize = MemoryLayout<Elf64_Phdr_t>.size
    let tableEnd          = headerSize + segments.count * programHeaderSize

    var nextPayloadOffset = roundUp(tableEnd, to: payloadAlignment)
    var bytes             = [UInt8](repeating: 0, count: nextPayloadOffset)

    var header = Elf64_Ehdr_t()
    header.e_ident[0] = 0x7F
    header.e_ident[1] = 0x45 // 'E'
    header.e_ident[2] = 0x4C // 'L'
    header.e_ident[3] = 0x46 // 'F'
    header.e_ident[4] = 2    // ELFCLASS64
    header.e_ident[5] = 1    // ELFDATA2LSB
    header.e_type      = 2      // ET_EXEC
    header.e_machine   = 0xB7   // EM_AARCH64
    header.e_version   = 1      // EV_CURRENT
    header.e_entry     = segments[0].virtual
    header.e_phoff     = UInt64(headerSize)
    header.e_ehsize    = UInt16(headerSize)
    header.e_phentsize = UInt16(programHeaderSize)
    header.e_phnum     = UInt16(segments.count)
    write(&header, into: &bytes, at: 0)

    for (index, segment) in segments.enumerated() {
        // Whatever the previous segment's bytes left between them and this one's
        // alignment, written as the zeros a linker would leave there.
        if bytes.count < nextPayloadOffset {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: nextPayloadOffset - bytes.count))
        }

        var programHeader = Elf64_Phdr_t()
        programHeader.p_type   = 1 // PT_LOAD
        programHeader.p_flags  = segment.flags
        programHeader.p_offset = UInt64(nextPayloadOffset)
        programHeader.p_vaddr  = segment.virtual
        programHeader.p_paddr  = segment.virtual
        programHeader.p_filesz = UInt64(segment.payload.count)
        programHeader.p_memsz  = segment.memorySize
        programHeader.p_align  = 4096

        write(&programHeader, into: &bytes, at: headerSize + index * programHeaderSize)
        bytes.append(contentsOf: segment.payload)
        bytes.append(contentsOf: segment.trailing)

        nextPayloadOffset = roundUp(bytes.count, to: payloadAlignment)
    }

    return bytes
}


/// A single-entry ustar archive: one header block, the payload padded to 512,
/// then the two zero blocks that end an archive.
///
/// The member's data therefore sits 512 bytes in, so it is page aligned only if
/// the archive itself is staged 512 bytes below a page boundary, which nothing
/// does. `makePageAlignedTarArchive` is the layout the real initrd has.
public func makeTarArchive(name: String, contents: [UInt8]) -> [UInt8] {
    var archive = tarHeader(name: name, size: contents.count)
    archive.append(contentsOf: contents)
    archive.append(contentsOf: [UInt8](
        repeating: 0,
        count: (512 - contents.count % 512) % 512 + 1024
    ))

    return archive
}


/// A ustar archive whose every member's data starts on a page boundary, built the
/// way `UstarWriter` builds the real initrd.
///
/// An `@pad` member goes in front of any header that would not land at an archive
/// offset of 3584 modulo 4096, which puts the data 512 bytes later on the page
/// boundary. `TarFileSystem.findFile` walks the filler like any other member and
/// skips it on the name.
public func makePageAlignedTarArchive(
    members: [(name: String, contents: [UInt8])]
) -> [UInt8] {
    var archive: [UInt8] = []

    for member in members {
        let modulo = archive.count % 4096
        if modulo != 3584 {
            let fillerSize = ((3072 - modulo) % 4096 + 4096) % 4096

            archive.append(contentsOf: tarHeader(name: "@pad", size: fillerSize))
            archive.append(contentsOf: [UInt8](repeating: 0, count: fillerSize))
        }

        archive.append(contentsOf: tarHeader(name: member.name, size: member.contents.count))
        archive.append(contentsOf: member.contents)
        archive.append(contentsOf: [UInt8](
            repeating: 0,
            count: (512 - member.contents.count % 512) % 512
        ))
    }

    archive.append(contentsOf: [UInt8](repeating: 0, count: 1024))

    return archive
}


// MARK: - Staging

/// The image and archive `layout` asks for, in one place, so the loader entry
/// point and the sharing-gate one cannot stage different bytes.
private func makeFixtureArchive(
    _ segments     : [ELFSegmentFixture],
    named name     : String,
    layout         : ELFFixtureLayout,
    followedBy next: [UInt8]? = nil
) -> [UInt8] {

    let image = makeELFImage(segments, payloadAlignment: layout.payloadAlignment)

    guard layout.pageAlignedMembers else {
        return makeTarArchive(name: name, contents: image)
    }

    var members = [(name: name, contents: image)]
    if let next { members.append((name: "next.bin", contents: next)) }

    return makePageAlignedTarArchive(members: members)
}


/// Copies `archive` into page-aligned host storage, `baseShift` bytes past the
/// boundary, and parks it in `Kernel.platformInfo` for the length of `body`.
///
/// `TarFileSystem` reads the archive base from the platform info at init and
/// `ImageSharing` reads the window on every decision, so the global has to carry
/// the fixture across both. The storage is page aligned rather than merely
/// malloc-aligned so the placement is decided here and not by the host allocator:
/// a member's data landing on a page boundary by luck would flip the sharing
/// verdict of every fixture that expects the copy path.
private func withStagedArchive(
    _ archive: [UInt8],
    baseShift: Int,
    _ body   : (PhysicalAddress, PhysicalAddress) -> Void
) {
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: archive.count + baseShift,
        alignment: 4096
    )
    defer { storage.deallocate() }

    let tar = storage + baseShift
    archive.withUnsafeBytes { tar.copyMemory(from: $0.baseAddress!, byteCount: archive.count) }

    let savedStart = Kernel.platformInfo.initrdStart
    let savedEnd   = Kernel.platformInfo.initrdEnd
    defer {
        Kernel.platformInfo.initrdStart = savedStart
        Kernel.platformInfo.initrdEnd   = savedEnd
    }

    let start = PhysicalAddress(UInt(bitPattern: tar))
    let end   = start + UInt64(archive.count)

    Kernel.platformInfo.initrdStart = start
    Kernel.platformInfo.initrdEnd   = end

    body(start, end)
}


/// The PT_LOAD headers of the staged image, read back out of the bytes the
/// filesystem points at rather than recomputed from the fixture, so a fixture
/// that wrote its table somewhere other than `e_phoff` shows up here.
private func readProgramHeaders(at base: PhysicalAddress) -> [Elf64_Phdr_t] {
    guard let image = UnsafeRawPointer(bitPattern: UInt(base)) else { return [] }

    let header = image.load(as: Elf64_Ehdr_t.self)

    var result: [Elf64_Phdr_t] = []
    for i in 0..<Int(header.e_phnum) {
        let offset = Int(header.e_phoff) + i * Int(header.e_phentsize)

        result.append(image.load(fromByteOffset: offset, as: Elf64_Phdr_t.self))
    }

    return result
}


// MARK: - Byte helpers

/// One 512-byte POSIX ustar header. The checksum field is left blank, which
/// `TarFileSystem` never verifies.
private func tarHeader(name: String, size: Int) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 512)

    put(name,          at: 0,   into: &header) // name
    put("0000644",     at: 100, into: &header) // mode
    put("0000000",     at: 108, into: &header) // uid
    put("0000000",     at: 116, into: &header) // gid
    put(octal(size),   at: 124, into: &header) // size
    put("00000000000", at: 136, into: &header) // mtime
    put("        ",    at: 148, into: &header) // chksum, unverified
    put("0",           at: 156, into: &header) // typeflag, regular file
    put("ustar",       at: 257, into: &header) // magic
    put("00",          at: 263, into: &header) // version

    return header
}


/// 11 octal digits, the width tar keeps a size in.
private func octal(_ value: Int) -> String {
    let digits = String(value, radix: 8)

    return String(repeating: "0", count: max(0, 11 - digits.count)) + digits
}


private func roundUp(_ value: Int, to alignment: Int) -> Int {
    (value + alignment - 1) & ~(alignment - 1)
}


private func put(_ text: String, at offset: Int, into bytes: inout [UInt8]) {
    for (index, byte) in Array(text.utf8).enumerated() { bytes[offset + index] = byte }
}


private func write<T>(_ value: inout T, into bytes: inout [UInt8], at offset: Int) {
    withUnsafeBytes(of: &value) { raw in
        bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
    }
}


/// Storage for `T` that is all zero bytes and was never run through an
/// initialiser, for the collaborators whose real `init` needs a booted machine.
private func allocateZeroed<T>(_ type: T.Type) -> UnsafeMutablePointer<T> {
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<T>.stride,
        alignment: MemoryLayout<T>.alignment
    )
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.stride)

    return storage.bindMemory(to: T.self, capacity: 1)
}


private func rawBytes<T>(of pointer: UnsafeMutablePointer<T>) -> [UInt8] {
    Array(UnsafeRawBufferPointer(start: pointer, count: MemoryLayout<T>.size))
}


private func nonZeroDescriptors(in table: UnsafeMutableRawPointer) -> Int {
    let entries = table.bindMemory(to: UInt64.self, capacity: 512)

    return (0..<512).count { entries[$0] != 0 }
}
