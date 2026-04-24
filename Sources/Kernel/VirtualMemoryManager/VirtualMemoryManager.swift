//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager {
    private let ppmPtr   : UnsafeMutablePointer<PhysicalPageManager>
    
    
    /// Root (TTBR1 - Address 0xFFFF...)
    private let kernelRootTable  : UnsafeMutablePointer<PageTableEntry>
    
    /// Root Temp (TTBR0 - Address 0x0000...)
    private let identityRootTable: UnsafeMutablePointer<PageTableEntry>
    
    private let kernelTableAddress  : PhysicalAddress
    private let identityTableAddress: PhysicalAddress
    
    static let physicalOffset: UInt64 = 0xFFFF800000000000
    static let pageSize      : UInt64 = 4096
    
    private func physToVirt<T>(_ phys: UInt64) -> UnsafeMutablePointer<T> {
        let offset = CPUArm64.isMMUEnabled() ? Self.physicalOffset : 0
        let virtAddr = phys + offset
        return UnsafeMutablePointer<T>(bitPattern: UInt(virtAddr))!
    }
    
    init(ppmPtr: UnsafeMutablePointer<PhysicalPageManager>) throws(PPMError) {
        self.ppmPtr = ppmPtr
        
        self.kernelTableAddress = try self.ppmPtr.pointee.alloc(4096).address
        self.identityTableAddress = try self.ppmPtr.pointee.alloc(4096).address
        
        self.kernelRootTable   = UnsafeMutablePointer<PageTableEntry>(bitPattern: UInt(kernelTableAddress))!
        self.identityRootTable = UnsafeMutablePointer<PageTableEntry>(bitPattern: UInt(identityTableAddress))!
        
        self.kernelRootTable.initialize(repeating: PageTableEntry(rawValue: 0), count: 512)
        self.identityRootTable.initialize(repeating: PageTableEntry(rawValue: 0), count: 512)
        
        
        let ramStart = PhysicalAddress(self.ppmPtr.pointee.ramStart)
        let kernelStart = getOfaddressWithSymbol(of: &_kernel_start)
        if ramStart < kernelStart {
            let flags: VirtualPageFlags = [.present, .pxn]
            try mapSection(startAddress: ramStart, endAddress: kernelStart, flags: flags)
        }
        
        var flags: VirtualPageFlags = [.present, .readOnly]
        try mapSection(
            startAddress: kernelStart,
            endAddress  : getOfaddressWithSymbol(of: &_text_end),
            flags       : flags
        )
        
        flags = [.present, .readOnly, .pxn]
        try mapSection(
            startAddress: getOfaddressWithSymbol(of: &_rodata_start),
            endAddress  : getOfaddressWithSymbol(of: &_rodata_end),
            flags       : flags
        )
        
        flags = [.present, .pxn]
        try mapSection(
            startAddress: getOfaddressWithSymbol(of: &_data_start),
            endAddress  : getOfaddressWithSymbol(of: &_kernel_end),
            flags       : flags
        )
        
        flags = [.present, .readOnly]
        try mapSection(
            startAddress: getOfaddressWithSymbol(of: &_evt_start),
            endAddress  : getOfaddressWithSymbol(of: &_evt_end),
            flags       : flags
        )
        
        flags = [.present, .pxn]
        let ramEnd = PhysicalAddress(self.ppmPtr.pointee.ramStart + self.ppmPtr.pointee.ramSize)
        try mapSection(
            startAddress: getOfaddressWithSymbol(of: &_evt_end),
            endAddress  : ramEnd,
            flags       : flags
        )
        
        let uartBase: UInt64 = 0x09000000
        try map(virtual: uartBase, physical: uartBase, type: .device)
        try map(virtual: Self.physicalOffset + uartBase, physical: uartBase, type: .device)
        
        CPUArm64.enableMMU(
            lowTable : self.identityTableAddress,
            highTable: self.kernelTableAddress
        )
        
        CPUArm64.flushTLB()
    }
    
    
    func map(
        virtual : VirtualAddress,
        physical: PhysicalAddress,
        type    : MemoryType,
        flags   : VirtualPageFlags = [.present]
    ) throws(PPMError) {
        
        var currentTable = (virtual >= Self.physicalOffset)
        ? kernelRootTable
        : identityRootTable
        
        currentTable = try mapTable(current: currentTable, virtual.l0)
        currentTable = try mapTable(current: currentTable, virtual.l1)
        currentTable = try mapTable(current: currentTable, virtual.l2)
        
        
        var entry = currentTable[virtual.l3]
        entry.physicalAddress = physical
        
        let attrs = type.attributes
        entry.mairIndex    = attrs.mair
        entry.shareability = attrs.share
        
        entry.flags = flags.union([.valid, .page, .accessFlag])
        currentTable[virtual.l3] = entry
        
        if CPUArm64.isMMUEnabled() {
            CPUArm64.flushTLB()
        }
    }
    
    private func mapTable(
        current: UnsafeMutablePointer<PageTableEntry>,
        _ index: Int
    ) throws(PPMError) -> UnsafeMutablePointer<PageTableEntry> {
        var entry = current[index]
        
        if !entry.isPresent {
            let newPage = try ppmPtr.pointee.alloc(4096)
            
            let newTablePtr: UnsafeMutablePointer<PageTableEntry> = physToVirt(newPage.address)
            newTablePtr.initialize(repeating: PageTableEntry(rawValue: 0), count: 512)
            
            entry.physicalAddress = newPage.address
            entry.flags = [.valid, .page]
            current[index] = entry
        }
        
        return physToVirt(entry.physicalAddress)
    }
    
    
    private func mapSection(
        startAddress: PhysicalAddress,
        endAddress  : PhysicalAddress,
        type        : MemoryType       = .normal,
        flags       : VirtualPageFlags = [.present]
    ) throws(PPMError) {
        
        let alignedStart = startAddress & ~(Self.pageSize - 1)
        let alignedEnd   = (endAddress  +   Self.pageSize - 1) & ~(Self.pageSize - 1)
        var currentAddr  = alignedStart
        
        while currentAddr < alignedEnd {
            try map(
                virtual : currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )
            
            try map(
                virtual : Self.physicalOffset + currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )
            
            currentAddr += Self.pageSize
        }
    }
}
