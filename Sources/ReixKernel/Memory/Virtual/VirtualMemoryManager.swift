//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager {
    private let ppmPtr: UnsafeMutablePointer<KernelPPM>
    
    
    /// Root (TTBR1 - Address 0xFFFF...)
    private let kernelRootTable  : UnsafeMutablePointer<PageTableEntry>
    
    /// Root Temp (TTBR0 - Address 0x0000...)
    private let identityRootTable: UnsafeMutablePointer<PageTableEntry>
    
    private let kernelTableAddress  : PhysicalAddress
    private let identityTableAddress: PhysicalAddress
    
    static let physicalOffset: UInt64 = 0xFFFF800000000000
    static let pageSize      : UInt64 = 4096
    
    static var asidCounter: ASID = 1
    
    public func physToVirt<T>(_ phys: UInt64) -> UnsafeMutablePointer<T> {
        let offset = Arch.MMU.isMMUEnabled() ? Self.physicalOffset : 0
        let virtAddr = phys + offset
        return UnsafeMutablePointer<T>(bitPattern: UInt(virtAddr))!
    }
    
    init(ppmPtr: UnsafeMutablePointer<KernelPPM>) throws(PPMError) {
        self.ppmPtr               = ppmPtr
        self.kernelTableAddress   = try self.ppmPtr.pointee.alloc(4096).address
        self.identityTableAddress = try self.ppmPtr.pointee.alloc(4096).address
        
        self.kernelRootTable = UnsafeMutablePointer<PageTableEntry>(
            bitPattern: UInt(kernelTableAddress)
        )!
        
        self.identityRootTable = UnsafeMutablePointer<PageTableEntry>(
            bitPattern: UInt(identityTableAddress)
        )!
        
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
        let kernelEnd = getOfaddressWithSymbol(of: &_kernel_end)
        try mapSection(
            startAddress: getOfaddressWithSymbol(of: &_data_start),
            endAddress  : kernelEnd,
            flags       : flags
        )
        
        flags = [.present, .pxn]
        let ramEnd = PhysicalAddress(self.ppmPtr.pointee.ramStart + self.ppmPtr.pointee.ramSize)
        
        let safeRamStart = (kernelEnd + (Self.pageSize - 1)) & ~(Self.pageSize - 1)
        try mapSection(
            startAddress: safeRamStart,
            endAddress  : ramEnd,
            flags       : flags
        )
        
        let uartBase = Kernel.platformInfo.uart.baseAddr
        try map(table: identityRootTable, virtual: uartBase, physical: uartBase, type: .device)
        try map(table: kernelRootTable, virtual: Self.physicalOffset + uartBase, physical: uartBase, type: .device)
        
        let gicDistributorBase  = Kernel.platformInfo.gic.gicdBase
        let gicCpuInterfaceBase = Kernel.platformInfo.gic.giccBase
        
        try map(
            table   : identityRootTable,
            virtual : gicDistributorBase,
            physical: gicDistributorBase,
            type    : .device
        )
        
        try map(
            table   : kernelRootTable,
            virtual : Self.physicalOffset + gicDistributorBase,
            physical: gicDistributorBase,
            type    : .device
        )
        
        try map(
            table   : identityRootTable,
            virtual : gicCpuInterfaceBase,
            physical: gicCpuInterfaceBase,
            type    : .device
        )
        
        try map(
            table   : kernelRootTable,
            virtual : Self.physicalOffset + gicCpuInterfaceBase,
            physical: gicCpuInterfaceBase,
            type    : .device
        )
        
        Arch.MMU.enableMMU(
            lowTable : self.identityTableAddress,
            highTable: self.kernelTableAddress
        )
        
        Arch.MMU.flushTLB()
    }
    
    
    public func createAddressSpace() throws(PPMError) -> AddressSpace {
        let page = try ppmPtr.pointee.alloc(4096, flag: .kernel)
        let rootTable: UnsafeMutablePointer<PageTableEntry> = physToVirt(page.address)
        rootTable.initialize(repeating: PageTableEntry(rawValue: 0), count: 512)
        try mapKernelIdentitySpace(table: rootTable)

        let asid = Self.asidCounter
        
        Self.asidCounter = Self.asidCounter &+ 1
        if Self.asidCounter == 0 {
            Self.asidCounter = 1
            Arch.MMU.flushTLB()
        }
        
        return AddressSpace(
            rootTablePhysical: page.address,
            asid             : asid
        )
    }
    
    public func mapUserPage(
        addressSpace: borrowing AddressSpace,
        virtual     : VirtualAddress,
        physical    : PhysicalAddress,
        flags       : VirtualPageFlags
    ) throws(PPMError) {
        let tablePointer: UnsafeMutablePointer<PageTableEntry> = physToVirt(addressSpace.rootTablePhysical)
        
        try map(
            table   : tablePointer,
            virtual : virtual,
            physical: physical,
            type    : .normal,
            flags   : flags
        )
    }
    
    
    // MARK: - Internals Handlers
    
    private func map(
        table   : UnsafeMutablePointer<PageTableEntry>,
        virtual : VirtualAddress,
        physical: PhysicalAddress,
        type    : MemoryType,
        flags   : VirtualPageFlags = [.present]
    ) throws(PPMError) {
        
        var currentTable = table
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
        
        if Arch.MMU.isMMUEnabled() {
            Arch.MMU.flushTLB()
        }
    }
    
    private func mapTable(
        current: UnsafeMutablePointer<PageTableEntry>,
        _ index: Int
    ) throws(PPMError) -> UnsafeMutablePointer<PageTableEntry> {
        var entry = current[index]
        
        if !entry.isPresent {
            let newPage = try ppmPtr.pointee.alloc(4096, flag: .kernel)
            
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
                table   : identityRootTable,
                virtual : currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )
            
            try map(
                table   : kernelRootTable,
                virtual : Self.physicalOffset + currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )
            
            currentAddr += Self.pageSize
        }
    }

    private func mapKernelIdentitySpace(
        table: UnsafeMutablePointer<PageTableEntry>
    ) throws(PPMError) {
        let ramStart = PhysicalAddress(self.ppmPtr.pointee.ramStart)
        let kernelStart = getOfaddressWithSymbol(of: &_kernel_start)

        if ramStart < kernelStart {
            try mapIdentitySection(
                table       : table,
                startAddress: ramStart,
                endAddress  : kernelStart,
                flags       : [.present, .pxn]
            )
        }

        try mapIdentitySection(
            table       : table,
            startAddress: kernelStart,
            endAddress  : getOfaddressWithSymbol(of: &_text_end),
            flags       : [.present, .readOnly]
        )

        try mapIdentitySection(
            table       : table,
            startAddress: getOfaddressWithSymbol(of: &_rodata_start),
            endAddress  : getOfaddressWithSymbol(of: &_rodata_end),
            flags       : [.present, .readOnly, .pxn]
        )

        let kernelEnd = getOfaddressWithSymbol(of: &_kernel_end)
        try mapIdentitySection(
            table       : table,
            startAddress: getOfaddressWithSymbol(of: &_data_start),
            endAddress  : kernelEnd,
            flags       : [.present, .pxn]
        )

        let ramEnd = PhysicalAddress(self.ppmPtr.pointee.ramStart + self.ppmPtr.pointee.ramSize)
        let safeRamStart = (kernelEnd + (Self.pageSize - 1)) & ~(Self.pageSize - 1)
        try mapIdentitySection(
            table       : table,
            startAddress: safeRamStart,
            endAddress  : ramEnd,
            flags       : [.present, .pxn]
        )

        let uartBase = Kernel.platformInfo.uart.baseAddr
        try map(table: table, virtual: uartBase, physical: uartBase, type: .device)

        let gicDistributorBase  = Kernel.platformInfo.gic.gicdBase
        let gicCpuInterfaceBase = Kernel.platformInfo.gic.giccBase
        try map(table: table, virtual: gicDistributorBase, physical: gicDistributorBase, type: .device)
        try map(table: table, virtual: gicCpuInterfaceBase, physical: gicCpuInterfaceBase, type: .device)
    }

    private func mapIdentitySection(
        table       : UnsafeMutablePointer<PageTableEntry>,
        startAddress: PhysicalAddress,
        endAddress  : PhysicalAddress,
        type        : MemoryType       = .normal,
        flags       : VirtualPageFlags = [.present]
    ) throws(PPMError) {
        let alignedStart = startAddress & ~(Self.pageSize - 1)
        let alignedEnd   = (endAddress + Self.pageSize - 1) & ~(Self.pageSize - 1)
        var currentAddr  = alignedStart

        while currentAddr < alignedEnd {
            try map(
                table   : table,
                virtual : currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )

            currentAddr += Self.pageSize
        }
    }
}
