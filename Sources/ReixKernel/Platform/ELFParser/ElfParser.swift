//
//  ElfParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

public struct ElfParser {
    
    private static let PT_LOAD : UInt32 = 1

    /// The MMU granule, not a number of this loader's own: the counts
    /// `ImageSharing` returns are in these pages and are multiplied by this.
    static let pageSize: UInt64 = UserSpaceLayout.pageSize

    /// `p_flags` bits. Internal rather than private because `ImageSharing` asks
    /// the same question of the same field, and one vocabulary cannot drift.
    static let PF_X: UInt32 = 0x1
    static let PF_W: UInt32 = 0x2
    static let PF_R: UInt32 = 0x4

    private static let ELFCLASS64 : UInt8  = 2
    private static let ELFDATA2LSB: UInt8  = 1
    private static let EV_CURRENT : UInt32 = 1
    private static let ET_EXEC    : UInt16 = 2
    private static let EM_AARCH64 : UInt16 = 0xB7

    /// Ceiling on the virtual span a single image may cover, enforced while
    /// the headers are still being read. `p_memsz` and `p_vaddr` are taken
    /// from the file and the mapping pass backs every page it cannot share with
    /// a frame of its own, so without this one crafted header, or two segments
    /// placed terabytes apart, drains the physical page manager 4 KiB at a time.
    ///
    /// The real binaries span 9 to 12 pages, so 64 MiB is pure headroom.
    private static let maxImageSize: UInt64 = 64 * 1024 * 1024

    private init() {}


    /// Read `handle` as an ELF64 executable and lay its PT_LOAD segments into
    /// `addressSpace`.
    ///
    /// ## The four passes
    ///
    /// 1. Headers. Every field the later passes trust is bounded here against
    ///    the size of the file, and the segment table is copied out so nothing
    ///    below re-reads a header it already validated.
    /// 2. W^X. One walk of the whole image span unioning `p_flags` per page,
    ///    which rejects a page that would end up writable *and* executable
    ///    before any collaborator has been called. It stays first for that
    ///    reason: a rejected layout must leave no VMA, no frame and no PTE.
    /// 3. Mapping, shareable segments first (see `ImageSharing`) and then a
    ///    page-driven walk over everything they did not claim. A shareable
    ///    segment's pages are aliased straight to the initrd frames, read-only,
    ///    and the walk backs each remaining page with a zeroed frame.
    /// 4. Copy, for the bytes that did not arrive by being aliased.
    ///
    /// ## Unwinding
    ///
    /// Every page mapped here is inside a region registered *before* it, which
    /// is what lets `destroyPartialAddressSpace` clean up a failure at any
    /// point by walking the VMA list alone. The two backings unwind differently
    /// and correctly: `.anonymous` regions release their frames, `.fileBacked`
    /// ones only drop translations, because the initrd frames were never this
    /// address space's to free.
    public static func loadSegments(
        handle      : FileHandle,
        fileSystem  : UnsafeMutablePointer<KernelInternalFileSystem>,
        addressSpace: borrowing AddressSpace,
        vmaManager  : UnsafeMutablePointer<VMAManager>,
        vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm         : UnsafeMutablePointer<PhysicalPageManager<BuddyAllocator>>
    ) throws(ElfError) -> LoadedELF {

        let fileSize = try Self.fileSize(handle: handle, fileSystem: fileSystem)

        var ehdr = Elf64_Ehdr_t()
        try Self.seek(handle: handle, fileSystem: fileSystem, to: 0)

        let headerRead = withUnsafeMutablePointer(to: &ehdr) { ptr in
            fileSystem.pointee.read(
                handle: handle,
                buffer: UnsafeMutableRawPointer(ptr),
                count : MemoryLayout<Elf64_Ehdr_t>.size
            )
        }

        guard case .success(let headerBytes) = headerRead,
              headerBytes == MemoryLayout<Elf64_Ehdr_t>.size
        else { throw .invalidMagicNumber }

        guard ehdr.e_ident[0] == 0x7F,
              ehdr.e_ident[1] == 0x45, // 'E'
              ehdr.e_ident[2] == 0x4C, // 'L'
              ehdr.e_ident[3] == 0x46
        else { throw .invalidMagicNumber }

        guard ehdr.e_ident[4] == Self.ELFCLASS64,
              ehdr.e_ident[5] == Self.ELFDATA2LSB,
              ehdr.e_version  == Self.EV_CURRENT,
              ehdr.e_type     == Self.ET_EXEC,
              ehdr.e_machine  == Self.EM_AARCH64
        else { throw .malformedLayout }
        
        guard ehdr.e_phentsize == UInt16(MemoryLayout<Elf64_Phdr_t>.size),
              ehdr.e_phnum      > 0
        else { throw .malformedLayout }

        let (tableSize, tableOverflow) = UInt64(ehdr.e_phnum)
            .multipliedReportingOverflow(by: UInt64(ehdr.e_phentsize))
        let (tableEnd , endOverflow  ) = ehdr.e_phoff
            .addingReportingOverflow(tableSize)

        guard !tableOverflow, !endOverflow, tableEnd <= fileSize else {
            throw .malformedLayout
        }

        var segments     = InlineArray<16, Elf64_Phdr_t>(repeating: Elf64_Phdr_t())
        var segmentCount = 0

        var loadBase: UInt64 = UInt64.max
        var loadEnd : UInt64 = 0

        for i in 0..<ehdr.e_phnum {
            var phdr = Elf64_Phdr_t()

            let phdrOffset = ehdr.e_phoff + UInt64(i) * UInt64(ehdr.e_phentsize)

            try Self.seek(handle: handle, fileSystem: fileSystem, to: phdrOffset)

            let phdrRead = withUnsafeMutablePointer(to: &phdr) { ptr in
                fileSystem.pointee.read(
                    handle: handle,
                    buffer: UnsafeMutableRawPointer(ptr),
                    count : MemoryLayout<Elf64_Phdr_t>.size
                )
            }

            guard case .success(let phdrBytes) = phdrRead,
                  phdrBytes == MemoryLayout<Elf64_Phdr_t>.size
            else { throw .malformedLayout }

            guard phdr.p_type == Self.PT_LOAD else { continue }

            guard phdr.p_memsz > 0 else { continue }

            let (fileEnd, fileEndOverflow) = phdr.p_offset
                .addingReportingOverflow(phdr.p_filesz)

            guard phdr.p_filesz <= phdr.p_memsz,
                  !fileEndOverflow,
                  fileEnd <= fileSize
            else { throw .malformedLayout }

            guard let range = Self.pageRange(of: phdr) else {
                throw .malformedLayout
            }

            let base = min(loadBase, range.start)
            let end  = max(loadEnd,  range.end)

            guard end - base <= Self.maxImageSize,
                  segmentCount < segments.count
            else { throw .malformedLayout }

            segments[segmentCount] = phdr
            segmentCount          += 1

            loadBase = base
            loadEnd  = end
        }

        guard loadBase != UInt64.max, loadEnd > loadBase else {
            throw .noLoadableSegments
        }

        guard ehdr.e_entry >= loadBase, ehdr.e_entry < loadEnd else {
            throw .malformedLayout
        }

        var pageVA = loadBase
        while pageVA < loadEnd {
            var permissions: VMAPermissions = [.user]

            for index in 0..<segmentCount {
                guard let range = Self.pageRange(of: segments[index]),
                      pageVA >= range.start,
                      pageVA <  range.end
                else { continue }

                let segmentFlags = segments[index].p_flags
                if (segmentFlags & Self.PF_W) != 0 { permissions.insert(.write)   }
                if (segmentFlags & Self.PF_X) != 0 { permissions.insert(.execute) }
            }

            guard !permissions.contains(.write) ||
                  !permissions.contains(.execute)
            else { throw .writeExecuteConflict }

            pageVA += Self.pageSize
        }

        // Leading pages of each segment `ImageSharing` cleared, indexed like
        // `segments`. A non-zero entry means that whole segment is handled below.
        var sharedRuns = InlineArray<16, UInt64>(repeating: 0)

        let residentBase = fileSystem.pointee.residentBase(handle: handle)

        var sharedPages  : UInt64 = 0
        var copiedPages  : UInt64 = 0
        let declinedStart         = ImageSharing.declinedTailPages

        for index in 0..<segmentCount {
            let phdr = segments[index]

            let shared = ImageSharing.shareablePageCount(
                of          : index,
                in          : segments.span,
                count       : segmentCount,
                residentBase: residentBase,
                fileSize    : fileSize
            )

            guard shared > 0, let base = residentBase else { continue }

            guard let range = Self.pageRange(of: phdr) else {
                throw .malformedLayout
            }

            sharedRuns[index] = shared

            // Shareable implies non-writable, so `.write` cannot appear here and
            // `toPageFlags` yields RX for text and R for rodata.
            var permissions: VMAPermissions = [.user]
            if (phdr.p_flags & Self.PF_R) != 0 { permissions.insert(.read)    }
            if (phdr.p_flags & Self.PF_X) != 0 { permissions.insert(.execute) }

            let sharedEnd = range.start + shared * Self.pageSize

            try Self.register(
                vmaManager : vmaManager,
                start      : range.start,
                end        : sharedEnd,
                permissions: permissions,
                backing    : .fileBacked
            )

            var cursor = range.start
            var offset = phdr.p_offset
            while cursor < sharedEnd {
                do {
                    try vmm.pointee.mapUserPage(
                        addressSpace: addressSpace,
                        virtual     : cursor,
                        physical    : base + offset,
                        flags       : permissions.toPageFlags()
                    )
                } catch { throw .mappingFailed(error) }

                cursor += Self.pageSize
                offset += Self.pageSize
            }

            sharedPages += shared

            guard sharedEnd < range.end else { continue }

            // What is left of a shared segment is zero-fill, or a tail page the
            // archive did not pad: this process's own, in its own region.
            try Self.register(
                vmaManager : vmaManager,
                start      : sharedEnd,
                end        : range.end,
                permissions: permissions,
                backing    : .anonymous
            )

            while cursor < range.end {
                try Self.materialize(
                    page        : cursor,
                    permissions : permissions,
                    addressSpace: addressSpace,
                    vmm         : vmm,
                    ppm         : ppm
                )

                copiedPages += 1
                cursor      += Self.pageSize
            }
        }

        pageVA = loadBase
        while pageVA < loadEnd {
            var permissions: VMAPermissions = [.user]
            var covered                     = false
            var alreadyMapped               = false

            for index in 0..<segmentCount {
                guard let range = Self.pageRange(of: segments[index]),
                      pageVA >= range.start,
                      pageVA <  range.end
                else { continue }

                if sharedRuns[index] > 0 { alreadyMapped = true }

                let segmentFlags = segments[index].p_flags
                if (segmentFlags & Self.PF_R) != 0 { permissions.insert(.read)    }
                if (segmentFlags & Self.PF_W) != 0 { permissions.insert(.write)   }
                if (segmentFlags & Self.PF_X) != 0 { permissions.insert(.execute) }

                covered = true
            }

            guard covered, !alreadyMapped else {
                pageVA += Self.pageSize
                continue
            }

            // One page at a time, and still one VMA per run: `registerRegion`
            // merges an anonymous region into the identical one before it.
            try Self.register(
                vmaManager : vmaManager,
                start      : pageVA,
                end        : pageVA + Self.pageSize,
                permissions: permissions,
                backing    : .anonymous
            )

            try Self.materialize(
                page        : pageVA,
                permissions : permissions,
                addressSpace: addressSpace,
                vmm         : vmm,
                ppm         : ppm
            )

            copiedPages += 1
            pageVA      += Self.pageSize
        }

        for index in 0..<segmentCount {
            let phdr = segments[index]

            // Bytes the aliased pages already carry, skipped so the write below
            // cannot reach an initrd frame through `physToVirt`.
            let aliased = sharedRuns[index] * Self.pageSize
            guard aliased < phdr.p_filesz else { continue }

            try Self.seek(
                handle    : handle,
                fileSystem: fileSystem,
                to        : phdr.p_offset + aliased
            )

            var remaining = phdr.p_filesz - aliased
            var va        = phdr.p_vaddr  + aliased
            while remaining > 0 {
                let pageBase = va &  ~(Self.pageSize - 1)
                let pageOff  = va &   (Self.pageSize - 1)
                let chunk    = min(Self.pageSize - pageOff, remaining)

                guard let phys = vmm.pointee.physicalAddressOf(
                    rootTable: addressSpace.rootTablePhysical,
                    virtual  : pageBase
                ) else { throw .malformedLayout }

                let pageDst: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(phys)

                let segmentRead = fileSystem.pointee.read(
                    handle: handle,
                    buffer: UnsafeMutableRawPointer(pageDst.advanced(by: Int(pageOff))),
                    count : Size(chunk)
                )

                guard case .success(let copied) = segmentRead,
                      copied == Size(chunk)
                else { throw .malformedLayout }

                va        += chunk
                remaining -= chunk
            }
        }

        ImageSharing.report(
            shared  : sharedPages,
            copied  : copiedPages,
            declined: ImageSharing.declinedTailPages - declinedStart
        )

        return LoadedELF(
            entryPoint: ehdr.e_entry,
            image     : nil,
            loadBase  : loadBase,
            loadEnd   : loadEnd
        )
    }


    // MARK: - Mapping helpers

    /// Register `[start, end)` and translate the VMA manager's refusals into
    /// this loader's vocabulary.
    ///
    /// Every mapping path goes through here first, because a page mapped outside
    /// a registered region is a page `destroyPartialAddressSpace` cannot see.
    private static func register(
        vmaManager : UnsafeMutablePointer<VMAManager>,
        start      : VirtualAddress,
        end        : VirtualAddress,
        permissions: VMAPermissions,
        backing    : BackingType
    ) throws(ElfError) {

        do {
            try vmaManager.pointee.registerRegion(
                start      : start,
                size       : end - start,
                permissions: permissions,
                backing    : backing,
                flags      : .none
            )
        } catch {

            if case .heapAllocationFailed(let inner) = error {
                throw .allocationFailed(inner)
            }

            throw .malformedLayout
        }
    }


    /// Back one page of an `.anonymous` region with a zeroed frame.
    ///
    /// Zeroed before it is mapped and not after: the frame comes from the buddy
    /// allocator carrying whatever the last owner left in it, and the copy pass
    /// only writes the bytes the file actually has.
    private static func materialize(
        page        : VirtualAddress,
        permissions : VMAPermissions,
        addressSpace: borrowing AddressSpace,
        vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm         : UnsafeMutablePointer<PhysicalPageManager<BuddyAllocator>>
    ) throws(ElfError) {

        let frame: PhysicalPage
        do { frame = try ppm.pointee.alloc(Int(Self.pageSize)) }
        catch { throw .allocationFailed(error) }

        let dst: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(frame.address)
        dst.initialize(repeating: 0, count: Int(Self.pageSize))

        do {
            try vmm.pointee.mapUserPage(
                addressSpace: addressSpace,
                virtual     : page,
                physical    : frame.address,
                flags       : permissions.toPageFlags()
            )
        } catch {
            try? ppm.pointee.release(frame.address)
            throw .mappingFailed(error)
        }
    }


    // MARK: - Untrusted input helpers

    /// Size of the file behind `handle`, obtained with a seek to `.end`
    /// because the FS interface exposes no stat on an open handle. Every
    /// offset the headers claim is bounded against this before use.
    private static func fileSize(
        handle    : FileHandle,
        fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>
    ) throws(ElfError) -> UInt64 {

        guard case .success(let size) = fileSystem.pointee.seek(
            handle: handle,
            to    : 0,
            method: .end
        ), size >= 0 else { throw .malformedLayout }

        return UInt64(size)
    }


    /// Seek whose result is not allowed to be dropped. `seek` rejects an
    /// offset past EOF and leaves `currentOffset` where the previous read
    /// stopped, so a discarded failure turns a bogus header offset into a read
    /// of whatever bytes happen to follow, adjacent file content
    /// reinterpreted as a header. The narrowing to `Size` is guarded for the
    /// same reason: it traps above `Size.max`.
    private static func seek(
        handle    : FileHandle,
        fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>,
        to offset : UInt64
    ) throws(ElfError) {

        guard offset <= UInt64(Size.max) else { throw .malformedLayout }

        guard case .success = fileSystem.pointee.seek(
            handle: handle,
            to    : Size(offset),
            method: .start
        ) else { throw .malformedLayout }
    }


    /// Page-aligned span a segment needs, or `nil` when p_vaddr/p_memsz leave
    /// the user window or would overflow when added.
    /// This is the only place `p_vaddr + p_memsz` is allowed to happen:
    /// `checkedPageRange` bounds the pair first, where a bare add on the raw fields traps.
    private static func pageRange(
        of phdr: Elf64_Phdr_t
    ) -> (start: VirtualAddress, end: VirtualAddress)? {

        UserSpaceLayout.checkedPageRange(
            address: phdr.p_vaddr,
            size   : phdr.p_memsz
        )
    }
}
