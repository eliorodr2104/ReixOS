//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager {
    let ppm             : PhysicalPageManager
    public let rootTable: PageTable
    
    public var isBootstrapping: Bool = true
    
    static let physicalOffset: UInt64 = 0xFFFF800000000000
    
    
    init(ppm: PhysicalPageManager) throws(PPMError) {
        self.ppm = ppm
        
        let page = try self.ppm.alloc(4096)
        self.rootTable = PageTable(
            page  : page,
            offset: 0
        )
        
        // Identity-map the entire kernel + EVT region so the CPU can keep
        // fetching instructions and accessing data after the MMU is enabled.
        // Without this, only the single 4KB page at 0x40000000 would be
        // mapped while the kernel itself lives at _kernel_start (0x40080000+),
        // causing an immediate translation fault on the first post-MMU fetch.
        let kernelStart = withUnsafePointer(to: &_kernel_start) { UInt64(UInt(bitPattern: $0)) }
        let evtEnd      = withUnsafePointer(to: &_evt_end)      { UInt64(UInt(bitPattern: $0)) }
        
        static let pageSize: UInt64 = 4096
        static let pageAlignMask    = pageSize - 1
        
        var addr   = kernelStart & ~pageAlignMask          // page-align down
        let mapEnd = (evtEnd + pageAlignMask) & ~pageAlignMask  // page-align up
        
        while addr < mapEnd {
            try map(virtual: addr, physical: addr, flags: .valid)
            addr += Self.pageSize
        }
        
        // Higher-half alias for the kernel start page (future higher-half transition).
        try map(virtual: Self.physicalOffset + kernelStart, physical: kernelStart, flags: .valid)
    }
    
    
    func map(
        virtual : UInt64,
        physical: UInt64,
        flags   : VirtualPageFlags
    ) throws(PPMError) {
        let intermediateIndices = virtual.indices
        let l3Index             = Int((virtual >> 12) & 0x1FF)
        
        var currentTablePtr = rootTable.table
        for index in intermediateIndices {
            var entry = currentTablePtr[index]
            
            if !entry.isPresent {
                let newPage = try ppm.alloc(4096)
                
                let offset = isBootstrapping ? 0 : UInt(Self.physicalOffset)
                let newTablePtr = UnsafeMutablePointer<PageTableEntry>(
                    bitPattern: UInt(newPage.address) + offset
                )!
                newTablePtr.initialize(repeating: PageTableEntry(rawValue: 0), count: 512)
                
                entry.physicalAddress = newPage.address
                entry.flags = [.valid, .page]
                currentTablePtr[index] = entry
            }
            
            let offset = isBootstrapping ? 0 : Self.physicalOffset
            let nextTableAddr = entry.physicalAddress + offset
            currentTablePtr = UnsafeMutablePointer<PageTableEntry>(bitPattern: UInt(nextTableAddr))!
        }
        
        var l3Entry = currentTablePtr[l3Index]
        l3Entry.physicalAddress = physical
        l3Entry.flags = flags.union([.valid, .page, .accessFlag])
        
        currentTablePtr[l3Index] = l3Entry
        CPUArm64.flushTLB()
    }
}
