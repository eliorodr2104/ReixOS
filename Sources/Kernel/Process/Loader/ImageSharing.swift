//
//  ImageSharing.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/08/2026.
//

/// Whether a PT_LOAD segment may be mapped straight out of the initrd instead
/// of being copied into frames of its own, and how many of its pages that
/// covers.
///
/// The archive is resident for the whole boot with its frames reserved, so an
/// immutable segment whose bytes are already page-aligned inside it needs no
/// frame at all: every instance's page tables can point at the same physical
/// page, read-only. Establishing that the alias is *safe* is this file's whole
/// job, and every condition below is one way it would not be:
///
/// * a writable segment would let one process rewrite another's image, and a
///   writable alias of a reserved frame has no owner to release it;
/// * no resident base means the filesystem cannot promise the bytes stay put,
///   which every non-initrd filesystem answers with `nil`;
/// * an unaligned base, `p_offset` or `p_vaddr` leaves the file bytes straddling
///   a page boundary, and a page can only be aliased whole. `INITRD_MODE=qemu`,
///   the default, lets QEMU choose the load address, so the unaligned case is a
///   first-class path and not a theoretical one;
/// * a page shared with another PT_LOAD would need the union of two permission
///   sets, which is exactly the case the W^X pass exists to reject.
///
/// The bytes between `p_filesz` and the end of the last page are the remaining
/// subtlety: a shared page hands userland whatever the archive holds there, so
/// they have to be zero *in the file*, and the loader falls back to a private
/// page when they are not. See `declinedTailPages`.
enum ImageSharing: Loggable {

    static let nameLog : StaticString = "[ELF ]"
    /// Above `info`, so the per-image report below stays quiet and the refusals
    /// still speak.
    ///
    /// That report prints on every spawn, which was one line per boot when a
    /// boot was all there was, and is one line per command now that there is a
    /// shell. It is also the line that lands in the middle of userland output
    /// and shreds it, which is why the boot matrix asserts nothing printed
    /// during a spawn. A declined tail is still a `warning` and still prints.
    static let logLevel: LogLevel     = .message

    /// The granule the returned count is in, so the caller multiplies by the
    /// same number this counted with. `ElfParser.pageSize` is the same constant.
    static let pageSize: UInt64 = UserSpaceLayout.pageSize


    /// Trailing pages this boot refused to share because the bytes past
    /// `p_filesz` were not zero, or ran past the end of the archive member.
    ///
    /// Counted and warned about rather than silently absorbed: every image this
    /// kernel ships is zero-padded to the next page by the linker, so a decline
    /// means the toolchain moved underneath the loader and the sharing figures
    /// are about to stop adding up.
    static var declinedTailPages: UInt64 = 0


    /// Leading pages of segment `index` the loader may map from `residentBase`,
    /// `0` when the whole segment has to be copied into private frames.
    ///
    /// A count and not a flag because the answer is per page at the tail: the
    /// pages fully covered by file bytes are always shareable once the segment
    /// itself is, while the page holding the end of `p_filesz` depends on what
    /// follows those bytes.
    ///
    /// Not a pure query, despite reading like one: a declined tail bumps
    /// `declinedTailPages` and logs. Call it **exactly once per segment per
    /// load**, which is what makes the delta `report` prints the declines of
    /// that image and not of an image asked about twice.
    ///
    /// - Parameter fileSize: size of the archive member, the bound the tail scan
    ///   is not allowed to read past.
    static func shareablePageCount(
        of index    : Int,
        in segments : Span<Elf64_Phdr_t>,
        count       : Int,
        residentBase: PhysicalAddress?,
        fileSize    : UInt64
    ) -> UInt64 {

        guard let residentBase, residentBase % pageSize == 0 else { return 0 }

        let phdr = segments[index]

        guard (phdr.p_flags & ElfParser.PF_W) == 0,
              phdr.p_offset % pageSize == 0,
              phdr.p_vaddr  % pageSize == 0
        else { return 0 }

        guard let range = UserSpaceLayout.checkedPageRange(
            address: phdr.p_vaddr,
            size   : phdr.p_memsz
        ) else { return 0 }

        guard isExclusive(index, in: segments, count: count, over: range) else {
            return 0
        }

        let pages     = (range.end - range.start) / pageSize
        let fullPages = min(phdr.p_filesz / pageSize, pages)

        guard initrdCovers(
            base  : residentBase,
            offset: phdr.p_offset,
            pages : fullPages
        ) else { return 0 }

        var shared = fullPages

        let tail = phdr.p_filesz % pageSize
        if tail != 0, fullPages < pages {
            let tailStart = phdr.p_offset + phdr.p_filesz
            let tailEnd   = phdr.p_offset + (fullPages + 1) * pageSize

            if initrdCovers(
                base  : residentBase,
                offset: phdr.p_offset,
                pages : fullPages + 1
            ), isZero(
                residentBase: residentBase,
                from        : tailStart,
                to          : tailEnd,
                fileSize    : fileSize
            ) {
                shared += 1

            } else {
                declinedTailPages += 1
                warning("segment tail past p_filesz is not zero, page copied instead of shared.")
            }
        }

        return shared
    }


    /// One line per image, so a boot log says whether sharing happened at all
    /// and what it covered instead of leaving it to be inferred from free-page
    /// arithmetic.
    static func report(shared: UInt64, copied: UInt64, declined: UInt64) {
        guard shared > 0 else {
            info("initrd sharing off: \(copied) image pages copied.")
            return
        }

        info("initrd sharing on: \(shared) pages mapped from the initrd, \(copied) copied, \(declined) tails declined.")
    }


    // MARK: - Conditions

    /// True when no other PT_LOAD touches any page of `range`.
    ///
    /// Page ranges and not byte ranges: two segments that share a page are one
    /// page-table entry with one permission set, whoever owns the bytes.
    private static func isExclusive(
        _ index    : Int,
        in segments: Span<Elf64_Phdr_t>,
        count      : Int,
        over range : (start: VirtualAddress, end: VirtualAddress)
    ) -> Bool {

        var other = 0
        while other < count {
            defer { other += 1 }

            guard other != index else { continue }

            guard let theirs = UserSpaceLayout.checkedPageRange(
                address: segments[other].p_vaddr,
                size   : segments[other].p_memsz
            ) else { continue }

            if theirs.start < range.end, range.start < theirs.end { return false }
        }

        return true
    }


    /// True when the `pages` pages starting at `base + offset` lie inside the
    /// initrd image.
    ///
    /// The second half of a bound whose first half is `TarFileSystem.open`, and
    /// deliberately redundant with it: this is the one condition whose failure is
    /// not a wrong mapping but a lasting one. A frame past `initrdEnd` is a frame
    /// the buddy allocator still owns and will re-issue, and an alias of it
    /// published read-only, executable when `PF_X`, into EL0 outlives whatever
    /// the allocator hands that page to next.
    private static func initrdCovers(
        base  : PhysicalAddress,
        offset: UInt64,
        pages : UInt64
    ) -> Bool {

        let archiveStart = Kernel.platformInfo.initrdStart
        let archiveEnd   = Kernel.platformInfo.initrdEnd

        guard archiveEnd > archiveStart, base >= archiveStart else { return false }

        let (dataStart, offsetOverflow) = base .addingReportingOverflow(offset)
        let (span     , spanOverflow  ) = pages.multipliedReportingOverflow(by: pageSize)
        guard !offsetOverflow, !spanOverflow else { return false }

        let (end, endOverflow) = dataStart.addingReportingOverflow(span)

        return !endOverflow && end <= archiveEnd
    }


    /// True when `[from, to)` of the archive member is entirely zero.
    ///
    /// A range ending past `fileSize` is not zero for this purpose but unknown:
    /// the bytes there belong to whatever the archive stored next, and sharing
    /// the page would publish them to userland.
    private static func isZero(
        residentBase: PhysicalAddress,
        from        : UInt64,
        to          : UInt64,
        fileSize    : UInt64
    ) -> Bool {

        guard to <= fileSize else { return false }

        // The initrd is identity-mapped, the same aliasing `OpenFileDescription`
        // relies on to read a member without translating anything.
        guard let base = UnsafeRawPointer(bitPattern: UInt(residentBase)) else {
            return false
        }

        var cursor = from
        while cursor < to {
            guard base.load(fromByteOffset: Int(cursor), as: UInt8.self) == 0 else {
                return false
            }

            cursor += 1
        }

        return true
    }
}
