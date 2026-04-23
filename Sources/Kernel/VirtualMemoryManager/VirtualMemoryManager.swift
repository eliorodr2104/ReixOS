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
        
        try map(virtual: 0x40000000, physical: 0x40000000, flags: .valid)
        try map(virtual: 0xFFFF800040000000, physical: 0x40000000, flags: .valid)
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
