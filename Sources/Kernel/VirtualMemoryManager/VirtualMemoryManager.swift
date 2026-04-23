//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager {
    private let ppmPtr   : UnsafeMutablePointer<PhysicalPageManager>
    public  let rootTable: UnsafeMutablePointer<PageTableEntry>
    
    public var isBootstrapping : Bool = true
    public var rootTableAddress: PhysicalAddress

    static let physicalOffset: UInt64 = 0xFFFF800000000000
    static let pageSize      : UInt64 = 4096
    static let pageAlignMask : UInt64 = pageSize - 1
    
    init(ppmPtr: UnsafeMutablePointer<PhysicalPageManager>) throws(PPMError) {
        self.ppmPtr = ppmPtr
        let page = try self.ppmPtr.pointee.alloc(4096)
        
        self.rootTableAddress = page.address
        self.rootTable = UnsafeMutablePointer<PageTableEntry>(
            bitPattern: UInt(self.rootTableAddress)
        )!
        self.rootTable.initialize(
            repeating: PageTableEntry(rawValue: 0),
            count: 512
        )
                        
        let ramStart: UInt64 = 0x40000000
        let mapEnd  : UInt64 = 0x40000000 + (2 * 1024 * 1024)
        
        var addr = ramStart
        while addr < mapEnd {
            try map(virtual: addr, physical: addr, flags: .valid)
            addr += Self.pageSize
        }
        
        let kernelStart = withUnsafePointer(to: &_kernel_start) { UInt64(UInt(bitPattern: $0)) }
        try map(virtual: Self.physicalOffset + kernelStart, physical: kernelStart, flags: .valid)
    }
    
    
    func map(
        virtual : UInt64,
        physical: UInt64,
        flags   : VirtualPageFlags
    ) throws(PPMError) {
        
        var currentTablePtr = rootTable
        currentTablePtr = try mapTable(currentTablePtr: currentTablePtr, virtual.l0)
        currentTablePtr = try mapTable(currentTablePtr: currentTablePtr, virtual.l1)
        currentTablePtr = try mapTable(currentTablePtr: currentTablePtr, virtual.l2)
        
        
        var l3Entry = currentTablePtr[virtual.l3]
        l3Entry.physicalAddress = physical
        l3Entry.flags = flags.union([.valid, .page, .accessFlag])
        
        currentTablePtr[virtual.l3] = l3Entry
        CPUArm64.flushTLB()
    }
    
    private func mapTable(
        currentTablePtr: UnsafeMutablePointer<PageTableEntry>,
        _ index: Int
    ) throws(PPMError) -> UnsafeMutablePointer<PageTableEntry> {
        var entry = currentTablePtr[index]
        
        if !entry.isPresent {
            let newPage = try ppmPtr.pointee.alloc(4096)
            
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
        
        return UnsafeMutablePointer<PageTableEntry>(bitPattern: UInt(nextTableAddr))!
    }
}
