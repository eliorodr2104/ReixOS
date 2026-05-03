//
//  ElfParser.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import CElf

public struct ElfParser {
    private static let PT_LOAD: UInt32 = 1
    
    private init() {}
    
    public static func loadSegments(
        elfAddress  : UInt64,
        addressSpace: borrowing AddressSpace,
        vmm         : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm         : UnsafeMutablePointer<PhysicalPageManager<BuddyAllocator>>,
    ) throws(PPMError) -> UInt64 {
        let ehdr = UnsafePointer<Elf64_Ehdr_t>(bitPattern: UInt(elfAddress))!
        
        guard ehdr.pointee.e_ident.0 == 0x7F && ehdr.pointee.e_ident.1 == 0x45 else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        var phdrAddr = elfAddress + ehdr.pointee.e_phoff
        for _ in 0..<ehdr.pointee.e_phnum {
            let phdr = UnsafePointer<Elf64_Phdr_t>(bitPattern: UInt(phdrAddr))!
            
            if phdr.pointee.p_type == PT_LOAD {
                let pagesNeeded = (phdr.pointee.p_memsz + 4095) / 4096
                let physicalSection = try ppm.pointee.alloc(Int(pagesNeeded * 4096))
                
                try vmm.pointee.mapUserPage(
                    addressSpace: addressSpace,
                    virtual     : phdr.pointee.p_vaddr,
                    physical    : physicalSection.address,
                    flags       : [.present, .userAccess, .pxn]
                )
                
                let dest: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(physicalSection.address)
                let source = UnsafePointer<UInt8>(bitPattern: UInt(elfAddress + phdr.pointee.p_offset))!
                
                // Copy p_filesz
                for i in 0..<Int(phdr.pointee.p_filesz) {
                    dest.advanced(by: i).pointee = source.advanced(by: i).pointee
                }
                
                // 4. Zero-fill (BSS)
                if phdr.pointee.p_memsz > phdr.pointee.p_filesz {
                    for i in Int(phdr.pointee.p_filesz)..<Int(phdr.pointee.p_memsz) {
                        dest.advanced(by: i).pointee = 0
                    }
                }
            }
            
            phdrAddr += UInt64(ehdr.pointee.e_phentsize)
        }
        
        return ehdr.pointee.e_entry
    }
}
