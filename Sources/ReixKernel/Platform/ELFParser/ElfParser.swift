//
//  ElfParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import CElf

public struct ElfParser {
    private static let PT_LOAD : UInt32 = 1
    private static let pageSize: UInt64 = 4096

    private static let PF_X: UInt32 = 0x1
    private static let PF_W: UInt32 = 0x2
    private static let PF_R: UInt32 = 0x4

    private init() {}

    public static func loadSegments(
        handle      : FileHandle,
        fileSystem  : UnsafeMutablePointer<KernelInternalFileSystem>,
        addressSpace: borrowing AddressSpace,
        vmaManager  : UnsafeMutablePointer<VMAManager>,
        vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm         : UnsafeMutablePointer<PhysicalPageManager<BuddyAllocator>>
    ) throws(ElfError) -> LoadedELF {
        
        var ehdr = Elf64_Ehdr_t()
        _ = fileSystem.pointee.seek(handle: handle, to: 0, method: .start)
        
        let headerRead = withUnsafeMutablePointer(to: &ehdr) { ptr in
            fileSystem.pointee.read(
                handle: handle,
                buffer: UnsafeMutableRawPointer(ptr),
                count : MemoryLayout<Elf64_Ehdr_t>.size
            )
        }
        
        switch headerRead {
            case .success(let bytes) where bytes == MemoryLayout<Elf64_Ehdr_t>.size: break
            case .success: throw .invalidMagicNumber
            case .failure(_): throw  .noLoadableSegments // .readError(err)
        }

        guard ehdr.e_ident.0 == 0x7F,
              ehdr.e_ident.1 == 0x45, // 'E'
              ehdr.e_ident.2 == 0x4C, // 'L'
              ehdr.e_ident.3 == 0x46
        else { throw .invalidMagicNumber }

        var loadBase: UInt64 = UInt64.max
        var loadEnd : UInt64 = 0

        for i in 0..<ehdr.e_phnum {
            var phdr = Elf64_Phdr_t()
            let phdrOffset = ehdr.e_phoff + UInt64(i) * UInt64(ehdr.e_phentsize)
            
            _ = fileSystem.pointee.seek(
                handle: handle,
                to    : Size(phdrOffset),
                method: .start
            )
            
            let phdrRead = withUnsafeMutablePointer(to: &phdr) { ptr in
                fileSystem.pointee.read(
                    handle: handle,
                    buffer: UnsafeMutableRawPointer(ptr),
                    count : MemoryLayout<Elf64_Phdr_t>.size
                )
            }
            
            if case .failure(_) = phdrRead {
                throw .noLoadableSegments /*.readError(err)*/
            }

            if phdr.p_type == PT_LOAD {
                let segmentStart = phdr.p_vaddr & ~(Self.pageSize - 1)
                let segmentEnd = (phdr.p_vaddr + phdr.p_memsz + Self.pageSize - 1) & ~(Self.pageSize - 1)

                if segmentStart < loadBase { loadBase = segmentStart }
                if segmentEnd > loadEnd { loadEnd = segmentEnd }
            }
        }

        guard loadBase != UInt64.max, loadEnd > loadBase else {
            throw .noLoadableSegments
        }

        let imageSize = loadEnd - loadBase


        var physicalImage: PhysicalPage
        do {
            physicalImage = try ppm.pointee.alloc(Int(imageSize))
        } catch { throw .allocationFailed(error) }

        let imageDest: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(physicalImage.address)
        imageDest.initialize(repeating: 0, count: Int(imageSize))

        var mappedOffset: UInt64 = 0
        do {
            while mappedOffset < imageSize {
                try vmm.pointee.mapUserPage(
                    addressSpace: addressSpace,
                    virtual     : loadBase + mappedOffset,
                    physical    : physicalImage.address + mappedOffset,
                    flags       : [.present, .userAccess, .pxn]
                )
                mappedOffset += Self.pageSize
            }
        } catch { throw .mappingFailed(error) }


        for i in 0..<ehdr.e_phnum {
            var phdr = Elf64_Phdr_t()
            let phdrOffset = ehdr.e_phoff + UInt64(i) * UInt64(ehdr.e_phentsize)
            
            _ = fileSystem.pointee.seek(
                handle: handle,
                to    : Size(phdrOffset),
                method: .start
            )
            
            _ = withUnsafeMutablePointer(to: &phdr) { ptr in
                fileSystem.pointee.read(
                    handle: handle,
                    buffer: UnsafeMutableRawPointer(ptr),
                    count : MemoryLayout<Elf64_Phdr_t>.size
                )
            }

            if phdr.p_type == PT_LOAD {
                let destOffset = Int(phdr.p_vaddr - loadBase)
                

                _ = fileSystem.pointee.seek(handle: handle, to: Size(phdr.p_offset), method: .start)
                

                let targetBuffer = UnsafeMutableRawPointer(imageDest.advanced(by: destOffset))
                
                let segmentRead = fileSystem.pointee.read(
                    handle: handle,
                    buffer: targetBuffer,
                    count : Size(phdr.p_filesz)
                )
                
                if case .failure(_) = segmentRead { throw .noLoadableSegments /*.readError(err)*/ }

                try? registerSegmentVMA(
                    phdr      : &phdr,
                    vmaManager: vmaManager
                )
            }
        }

        return LoadedELF(
            entryPoint: ehdr.e_entry,
            image     : physicalImage,
            loadBase  : loadBase,
            loadEnd   : loadEnd
        )
    }

    private static func registerSegmentVMA(
        phdr      : UnsafePointer<Elf64_Phdr_t>,
        vmaManager: UnsafeMutablePointer<VMAManager>
    ) throws(VMAError) {
        let segmentStart =  phdr.pointee.p_vaddr & ~(Self.pageSize - 1)
        let segmentEnd   = (phdr.pointee.p_vaddr + phdr.pointee.p_memsz + Self.pageSize - 1) & ~(Self.pageSize - 1)

        guard segmentEnd > segmentStart else { throw .invalidLayout }

        var permissions: VMAPermissions = [.user]
        if (phdr.pointee.p_flags & PF_R) != 0 { permissions.insert(.read)    }
        if (phdr.pointee.p_flags & PF_W) != 0 { permissions.insert(.write)   }
        if (phdr.pointee.p_flags & PF_X) != 0 { permissions.insert(.execute) }

        try vmaManager.pointee.registerRegion(
            start      : segmentStart,
            size       : segmentEnd - segmentStart,
            permissions: permissions,
            backing    : .fileBacked,
            flags      : .none
        )
    }
}
