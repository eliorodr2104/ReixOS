//
//  ELFPlanner.swift
//  ReixOS
//

import ReixABI

public enum ELFPlanner {
    private static let headerSize            = 64
    private static let programHeaderSize     = 56
    private static let maximumProgramHeaders = 64
    private static let maximumLoadSegments   = 16
    private static let maximumImageSpan      : UInt64 = 64 * 1024 * 1024
    private static let maximumImageRegions   = 31 // one task region is reserved for the stack

    private static let loadType   : UInt32 = 1
    private static let flagExecute: UInt32 = 1
    private static let flagWrite  : UInt32 = 2
    private static let flagRead   : UInt32 = 4
    private static let knownFlags : UInt32 = 7

    private struct Segment {
        let fileOffset    : UInt64
        let virtualAddress: UInt64
        let fileSize      : UInt64
        let memorySize    : UInt64
        let flags         : UInt32
        let pageStart     : UInt64
        let pageEnd       : UInt64
    }

    public static func plan<Source: ELFByteSource>(
        from source: inout Source
    ) -> Result<ELFLoadPlan, ELFPlanError> {
        var header = InlineArray<64, UInt8>(repeating: 0)
        guard read(&source, at: 0, into: &header) else { return .failure(.truncated) }

        guard header[0] == 0x7F,
              header[1] == 0x45,
              header[2] == 0x4C,
              header[3] == 0x46
        else { return .failure(.notELF) }

        guard header[4] == 2, // ELFCLASS64
              header[5] == 1, // ELFDATA2LSB
              header[6] == 1,
              u16(header, 16) == 2, // ET_EXEC
              u16(header, 18) == 0xB7,
              u32(header, 20) == 1,
              u16(header, 52) == UInt16(headerSize),
              u16(header, 54) == UInt16(programHeaderSize)
        else { return .failure(.unsupported) }

        let entry       = u64(header, 24)
        let tableOffset = u64(header, 32)
        let headerCount = Int(u16(header, 56))

        guard headerCount > 0 else { return .failure(.malformed) }
        guard headerCount <= maximumProgramHeaders else {
            return .failure(.tooManyHeaders)
        }

        let (tableBytes, tableBytesOverflow) = UInt64(headerCount)
            .multipliedReportingOverflow(by: UInt64(programHeaderSize))
        let (tableEnd, tableEndOverflow) = tableOffset
            .addingReportingOverflow(tableBytes)
        guard !tableBytesOverflow, !tableEndOverflow, tableEnd <= source.size else {
            return .failure(.truncated)
        }

        var segments     = InlineArray<16, Segment?>(repeating: nil)
        var segmentCount = 0
        var loadBase     = UInt64.max
        var loadEnd      : UInt64 = 0

        for index in 0..<headerCount {
            var program = InlineArray<56, UInt8>(repeating: 0)
            let offset  = tableOffset + UInt64(index * programHeaderSize)
            guard read(&source, at: offset, into: &program) else {
                return .failure(.truncated)
            }

            guard u32(program, 0) == loadType else { continue }

            let flags          = u32(program, 4)
            let fileOffset     = u64(program, 8)
            let virtualAddress = u64(program, 16)
            let fileSize       = u64(program, 32)
            let memorySize     = u64(program, 40)
            let alignment      = u64(program, 48)

            guard memorySize > 0 else { continue }
            guard segmentCount < maximumLoadSegments else {
                return .failure(.tooManySegments)
            }
            guard flags & ~knownFlags == 0,
                  flags & flagRead != 0,
                  fileSize <= memorySize
            else { return .failure(.malformed) }

            if alignment > 1 {
                guard alignment & (alignment - 1) == 0,
                      virtualAddress & (alignment - 1) == fileOffset & (alignment - 1)
                else { return .failure(.malformed) }
            }

            let (fileEnd, fileOverflow) = fileOffset.addingReportingOverflow(fileSize)
            let (memoryEnd, memoryOverflow) = virtualAddress.addingReportingOverflow(memorySize)
            guard !fileOverflow, fileEnd <= source.size,
                  !memoryOverflow,
                  let pageEnd = alignedUp(memoryEnd),
                  virtualAddress >= TaskABI.userMin,
                  pageEnd <= TaskABI.heapLimit - TaskABI.pageSize
            else { return .failure(.addressOutsideUserImage) }

            let pageStart = virtualAddress & ~(TaskABI.pageSize - 1)
            guard pageEnd > pageStart else { return .failure(.malformed) }

            for previous in 0..<segmentCount {
                guard let existing = segments[previous] else { continue }
                let existingEnd = existing.virtualAddress + existing.memorySize
                if virtualAddress < existingEnd,
                   existing.virtualAddress < memoryEnd {
                    return .failure(.malformed)
                }
            }

            let segment = Segment(
                fileOffset: fileOffset,
                virtualAddress: virtualAddress,
                fileSize: fileSize,
                memorySize: memorySize,
                flags: flags,
                pageStart: pageStart,
                pageEnd: pageEnd
            )
            segments[segmentCount] = segment
            segmentCount += 1

            if pageStart < loadBase { loadBase = pageStart }
            if pageEnd > loadEnd { loadEnd = pageEnd }
        }

        guard segmentCount > 0, loadBase != UInt64.max, loadEnd > loadBase else {
            return .failure(.malformed)
        }
        guard loadEnd - loadBase <= maximumImageSpan else {
            return .failure(.imageTooLarge)
        }

        var regions            = InlineArray<31, ELFLoadRegion?>(repeating: nil)
        var regionCount        = 0
        var imagePages         : UInt32 = 0
        var currentAddress     : UInt64 = 0
        var currentPages       : UInt32 = 0
        var currentPermissions = TaskMemoryPermissions([])

        func finishRegion() -> Bool {
            guard currentPages > 0 else { return true }
            guard regionCount < maximumImageRegions else { return false }

            regions[regionCount] = ELFLoadRegion(
                address: currentAddress,
                pages: currentPages,
                permissions: currentPermissions
            )
            regionCount += 1
            imagePages += currentPages
            currentPages = 0
            return true
        }

        var page = loadBase
        while page < loadEnd {
            var flags   : UInt32 = 0
            var covered = false

            for index in 0..<segmentCount {
                guard let segment = segments[index],
                      segment.pageStart <= page,
                      page < segment.pageEnd
                else { continue }

                covered = true
                flags |= segment.flags
            }

            if !covered {
                guard finishRegion() else { return .failure(.imageTooLarge) }
                page += TaskABI.pageSize
                continue
            }

            guard flags & flagWrite == 0 || flags & flagExecute == 0 else {
                return .failure(.writeExecuteConflict)
            }

            var permissions: TaskMemoryPermissions = [.read]
            if flags & flagWrite != 0 { permissions.insert(.write) }
            if flags & flagExecute != 0 { permissions.insert(.execute) }

            let contiguous = currentPages > 0 &&
                currentAddress + UInt64(currentPages) * TaskABI.pageSize == page
            let samePermissions = permissions == currentPermissions
            let belowMapBound   = currentPages < TaskABI.maximumPagesPerMapping

            if !contiguous || !samePermissions || !belowMapBound {
                guard finishRegion() else { return .failure(.imageTooLarge) }
                currentAddress = page
                currentPermissions = permissions
            }

            currentPages += 1
            page += TaskABI.pageSize
        }
        guard finishRegion() else { return .failure(.imageTooLarge) }

        var entryExecutable = false
        for index in 0..<regionCount {
            guard let region = regions[index] else { continue }
            let end = region.address + UInt64(region.pages) * TaskABI.pageSize
            if region.address <= entry, entry < end,
               region.permissions.contains(.execute) {
                entryExecutable = true
                break
            }
        }
        guard entryExecutable else { return .failure(.entryNotExecutable) }

        var copies    = InlineArray<16, ELFCopy?>(repeating: nil)
        var copyCount = 0
        for index in 0..<segmentCount {
            guard let segment = segments[index], segment.fileSize > 0 else { continue }
            copies[copyCount] = ELFCopy(
                fileOffset    : segment.fileOffset,
                virtualAddress: segment.virtualAddress,
                byteCount     : segment.fileSize
            )
            copyCount += 1
        }

        return .success(ELFLoadPlan(
            entry       : entry,
            programBreak: loadEnd,
            imagePages  : imagePages,
            regions     : regions,
            regionCount : regionCount,
            copies      : copies,
            copyCount   : copyCount
        ))
    }

    private static func alignedUp(_ value: UInt64) -> UInt64? {
        let (sum, overflow) = value.addingReportingOverflow(TaskABI.pageSize - 1)
        guard !overflow else { return nil }
        return sum & ~(TaskABI.pageSize - 1)
    }

    private static func read<Source: ELFByteSource, let N: Int>(
        _ source  : inout Source,
        at offset : UInt64,
        into bytes: inout InlineArray<N, UInt8>
    ) -> Bool {
        withUnsafeMutableBytes(of: &bytes) { raw in
            source.read(
                at  : offset,
                into: raw.baseAddress!,
                count: N
            )
        }
    }

    private static func u16<let N: Int>(
        _ bytes : InlineArray<N, UInt8>,
        _ offset: Int
    ) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32<let N: Int>(
        _ bytes : InlineArray<N, UInt8>,
        _ offset: Int
    ) -> UInt32 {
        UInt32(bytes[offset]) |
        UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 |
        UInt32(bytes[offset + 3]) << 24
    }

    private static func u64<let N: Int>(
        _ bytes : InlineArray<N, UInt8>,
        _ offset: Int
    ) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}
