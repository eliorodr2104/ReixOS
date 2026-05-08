//
//  ElfParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import CElf

public struct ElfParser {
    private static let PT_LOAD: UInt32 = 1
    private static let pageSize: UInt64 = 4096
    
    private init() {}

    public struct LoadedELF {
        public let entryPoint: UInt64
        public let image     : PhysicalPage
        public let loadBase  : UInt64
        public let loadEnd   : UInt64
    }
    
    public static func loadSegments(
        elfAddress  : UInt64,
        addressSpace: borrowing AddressSpace,
        vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm         : UnsafeMutablePointer<PhysicalPageManager<BuddyAllocator>>,
    ) throws(PPMError) -> LoadedELF {
        let ehdr = UnsafePointer<Elf64_Ehdr_t>(bitPattern: UInt(elfAddress))!
        
        guard ehdr.pointee.e_ident.0 == 0x7F && ehdr.pointee.e_ident.1 == 0x45 else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        var loadBase: UInt64 = UInt64.max
        var loadEnd : UInt64 = 0

        var phdrAddr = elfAddress + ehdr.pointee.e_phoff
        for _ in 0..<ehdr.pointee.e_phnum {
            let phdr = UnsafePointer<Elf64_Phdr_t>(bitPattern: UInt(phdrAddr))!
            
            if phdr.pointee.p_type == PT_LOAD {
                let segmentStart = phdr.pointee.p_vaddr & ~(Self.pageSize - 1)
                let segmentEnd = (phdr.pointee.p_vaddr + phdr.pointee.p_memsz + Self.pageSize - 1) & ~(Self.pageSize - 1)

                if segmentStart < loadBase { loadBase = segmentStart }
                if segmentEnd > loadEnd { loadEnd = segmentEnd }
            }
            
            phdrAddr += UInt64(ehdr.pointee.e_phentsize)
        }

        guard loadBase != UInt64.max, loadEnd > loadBase else {
            throw .allocationFailed(reason: .fullMemory)
        }

        let imageSize = loadEnd - loadBase
        let physicalImage = try ppm.pointee.alloc(Int(imageSize))
        let imageDest: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(physicalImage.address)

        for i in 0..<Int(imageSize) {
            imageDest.advanced(by: i).pointee = 0
        }

        var mappedOffset: UInt64 = 0
        while mappedOffset < imageSize {
            try vmm.pointee.mapUserPage(
                addressSpace: addressSpace,
                virtual     : loadBase + mappedOffset,
                physical    : physicalImage.address + mappedOffset,
                flags       : [.present, .userAccess, .pxn]
            )

            mappedOffset += Self.pageSize
        }

        phdrAddr = elfAddress + ehdr.pointee.e_phoff
        for _ in 0..<ehdr.pointee.e_phnum {
            let phdr = UnsafePointer<Elf64_Phdr_t>(bitPattern: UInt(phdrAddr))!

            if phdr.pointee.p_type == PT_LOAD {
                let destOffset = Int(phdr.pointee.p_vaddr - loadBase)
                let source = UnsafePointer<UInt8>(bitPattern: UInt(elfAddress + phdr.pointee.p_offset))!

                for i in 0..<Int(phdr.pointee.p_filesz) {
                    imageDest.advanced(by: destOffset + i).pointee = source.advanced(by: i).pointee
                }
            }

            phdrAddr += UInt64(ehdr.pointee.e_phentsize)
        }
        
        return LoadedELF(
            entryPoint: ehdr.pointee.e_entry,
            image     : physicalImage,
            loadBase  : loadBase,
            loadEnd   : loadEnd
        )
    }
}
