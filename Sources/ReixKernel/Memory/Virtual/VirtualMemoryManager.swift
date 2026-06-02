//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager {
    
    private let ppmPtr              : UnsafeMutablePointer<KernelPPM>
        
    /// Root (TTBR1 - Address 0xFFFF...)
    private let kernelRootTable     : UnsafeMutablePointer<Arch.PageTableEntry>
    
    /// Root Temp (TTBR0 - Address 0x0000...)
    private let identityRootTable   : UnsafeMutablePointer<Arch.PageTableEntry>
    
    private let kernelTableAddress  : PhysicalAddress
    private let identityTableAddress: PhysicalAddress
    
    static let physicalOffset       : UInt64 = 0xFFFF800000000000
    static let pageSize             : UInt64 = 4096

    /// Monotonically increasing ASID source for newly created address spaces.
    /// Wraps to `1` (skipping `0`, reserved for the kernel TTBR1 space) and
    /// flushes the TLB on wrap to avoid stale tagged entries.
    private var asidCounter         : ASID = 1
    
    
    public func physToVirt<T>(_ phys: UInt64) -> UnsafeMutablePointer<T> {
        let offset = Arch.MMU.isMMUEnabled() ? Self.physicalOffset : 0
        let virtAddr = phys + offset
        return UnsafeMutablePointer<T>(bitPattern: UInt(virtAddr))!
    }
    
    init(ppmPtr: UnsafeMutablePointer<KernelPPM>) throws(PPMError) {
        self.ppmPtr               = ppmPtr
        let pageKernelTable       = try self.ppmPtr.pointee.alloc(4096)
        self.kernelTableAddress   = pageKernelTable.address
        
        let pageIdentityTable     = try self.ppmPtr.pointee.alloc(4096)
        self.identityTableAddress = pageIdentityTable.address
        
        self.kernelRootTable = UnsafeMutablePointer<Arch.PageTableEntry>(
            bitPattern: UInt(kernelTableAddress)
        )!
        
        self.identityRootTable = UnsafeMutablePointer<Arch.PageTableEntry>(
            bitPattern: UInt(identityTableAddress)
        )!
        
        
        self.kernelRootTable.initialize(
            repeating: Arch.PageTableEntry(rawValue: 0),
            count    : 512
        )
        self.identityRootTable.initialize(
            repeating: Arch.PageTableEntry(rawValue: 0),
            count    : 512
        )
        
        
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
        
        let initrdBase = Kernel.platformInfo.initrdStart
        let initrdEnd  = Kernel.platformInfo.initrdEnd
        try mapSection(
            startAddress: initrdBase,
            endAddress: initrdEnd,
            type: .normal,
            flags: [.present, .readOnly, .pxn]
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
    
    
    public mutating func createAddressSpace() throws(PPMError) -> AddressSpace {
        let page = try ppmPtr.pointee.alloc(4096, flag: .kernel)
        let rootTable: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(page.address)
        rootTable.initialize(repeating: Arch.PageTableEntry(rawValue: 0), count: 512)
        try mapKernelIdentitySpace(table: rootTable)

        let asid = self.asidCounter

        self.asidCounter = self.asidCounter &+ 1
        if self.asidCounter == 0 {
            self.asidCounter = 1
            Arch.MMU.flushTLB()
        }

        return AddressSpace(
            rootTablePhysical: page,
            asid             : asid,
            vmaManager       : nil
        )
    }


    public func destroyAddressSpace(
        addressSpace: consuming AddressSpace
    ) throws(PPMError) {
        // The exiting process root table may still be installed in TTBR0_EL1.
        // The kernel executes from the low identity map provided by TTBR0
        // (VBAR and kernel text live there), so freeing the live root and
        // flushing the TLB would invalidate the kernel's own code/vector
        // mappings and wedge the CPU in a translation-fault loop. Detach by
        // installing the kernel identity root in TTBR0 before reclaiming the
        // page; the kernel identity root carries the same kernel mappings and
        // is never freed.
        Arch.MMU.switchUserAddressSpace(self.identityTableAddress)

        try ppmPtr.pointee.freeOwnedKernelPage(addressSpace.rootTablePhysical)
        Arch.MMU.flushTLB()
    }


    public func mapUserPage(
        rootTable: PhysicalPage,
        virtual  : VirtualAddress,
        physical : PhysicalAddress,
        flags    : VirtualPageFlags,
        flushTLB : Bool = true
    ) throws(PPMError) {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable.address)

        try map(
            table   : tablePointer,
            virtual : virtual,
            physical: physical,
            type    : .normal,
            flags   : flags,
            flushTLB: flushTLB
        )
    }
    
    
    public func protectUserPage(
        rootTable: PhysicalPage,
        virtual  : VirtualAddress,
        flags    : VirtualPageFlags
    ) throws(PPMError) {
        guard let phys = physicalAddressOf(
            rootTable: rootTable,
            virtual  : virtual
        ) else { return }
        
        try mapUserPage(
            rootTable: rootTable,
            virtual  : virtual,
            physical : phys,
            flags    : flags
        )
    }


    public func mapUserPage(
        addressSpace: borrowing AddressSpace,
        virtual     : VirtualAddress,
        physical    : PhysicalAddress,
        flags       : VirtualPageFlags,
        flushTLB    : Bool = true
    ) throws(PPMError) {
        let rootTable = addressSpace.rootTablePhysical
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable.address)

        try map(
            table   : tablePointer,
            virtual : virtual,
            physical: physical,
            type    : .normal,
            flags   : flags,
            flushTLB: flushTLB
        )
    }
    

    public func unmapUserPage(
        rootTable: PhysicalPage,
        virtual  : VirtualAddress
    ) throws(PPMError) {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable.address)
        guard let leafTable = lookupLeafTable(table: tablePointer, virtual: virtual) else {
            return
        }

        leafTable[virtual.l3] = Arch.PageTableEntry(rawValue: 0)

        if Arch.MMU.isMMUEnabled() {
            Arch.MMU.flushTLB()
        }
    }


    public func unmapUserPage(
        addressSpace: borrowing AddressSpace,
        virtual     : VirtualAddress
    ) throws(PPMError) {
        try unmapUserPage(
            rootTable: addressSpace.rootTablePhysical,
            virtual  : virtual
        )
    }


    public func physicalAddressOf(
        rootTable: PhysicalPage,
        virtual  : VirtualAddress
    ) -> PhysicalAddress? {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable.address)
        guard let leafTable = lookupLeafTable(table: tablePointer, virtual: virtual) else {
            return nil
        }

        let entry = leafTable[virtual.l3]
        guard entry.isPresent else { return nil }

        return entry.physicalAddress
    }


    public func unmapAndFreeUserPage(
        rootTable: PhysicalPage,
        virtual  : VirtualAddress
    ) throws(PPMError) {
        guard let phys = physicalAddressOf(
            rootTable: rootTable,
            virtual  : virtual
        ) else { return }

        try ppmPtr.pointee.free(PhysicalPage(address: phys, order: 0))
        try unmapUserPage(
            rootTable: rootTable,
            virtual  : virtual
        )
    }
    
    
    // MARK: - Internals Handlers
    
    private func map(
        table       : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual     : VirtualAddress,
        physical    : PhysicalAddress,
        type        : MemoryType,
        flags       : VirtualPageFlags = [.present],
        defaultFlags: VirtualPageFlags = [.valid, .page, .accessFlag],
        flushTLB    : Bool             = true
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
        entry.flags        = flags.union(defaultFlags)
        
        currentTable[virtual.l3] = entry
        
        if Arch.MMU.isMMUEnabled() && flushTLB {
            Arch.MMU.flushTLB()
        }
    }
    
    private func mapTable(
        current: UnsafeMutablePointer<Arch.PageTableEntry>,
        _ index: Int
    ) throws(PPMError) -> UnsafeMutablePointer<Arch.PageTableEntry> {
        var entry = current[index]
        
        if !entry.isPresent {
            let newPage = try ppmPtr.pointee.alloc(4096, flag: .kernel)
            
            let newTablePtr: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(newPage.address)
            newTablePtr.initialize(repeating: Arch.PageTableEntry(rawValue: 0), count: 512)
            
            entry.physicalAddress = newPage.address
            entry.flags = [.valid, .page]
            current[index] = entry
        }
        
        return physToVirt(entry.physicalAddress)
    }

    private func lookupLeafTable(
        table  : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual: VirtualAddress
    ) -> UnsafeMutablePointer<Arch.PageTableEntry>? {
        var currentTable = table
                
        let indexes: InlineArray<3, Int> = [virtual.l0, virtual.l1, virtual.l2]

        for i in 0..<indexes.count {
            let index = indexes[i]
            let entry = currentTable[index]
            guard entry.isPresent else { return nil }
            currentTable = physToVirt(entry.physicalAddress)
        }

        return currentTable
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

    
    private func unmapKernelIdentitySpace(
        table: UnsafeMutablePointer<Arch.PageTableEntry>
    ) throws(PPMError) {
        let ramStart = PhysicalAddress(self.ppmPtr.pointee.ramStart)
        let kernelStart = getOfaddressWithSymbol(of: &_kernel_start)
        
        if ramStart < kernelStart {
            try mapUserRootSection(
                table       : table,
                startAddress: ramStart,
                endAddress  : kernelStart,
                flags       : []
            )
        }
        
        try mapUserRootSection(
            table       : table,
            startAddress: kernelStart,
            endAddress  : getOfaddressWithSymbol(of: &_text_end),
            flags       : []
        )
        
        try mapUserRootSection(
            table       : table,
            startAddress: getOfaddressWithSymbol(of: &_rodata_start),
            endAddress  : getOfaddressWithSymbol(of: &_rodata_end),
            flags       : []
        )
        
        let kernelEnd = getOfaddressWithSymbol(of: &_kernel_end)
        try mapUserRootSection(
            table       : table,
            startAddress: getOfaddressWithSymbol(of: &_data_start),
            endAddress  : kernelEnd,
            flags       : []
        )
        
        let ramEnd = PhysicalAddress(self.ppmPtr.pointee.ramStart + self.ppmPtr.pointee.ramSize)
        let safeRamStart = (kernelEnd + (Self.pageSize - 1)) & ~(Self.pageSize - 1)
        try mapUserRootSection(
            table       : table,
            startAddress: safeRamStart,
            endAddress  : ramEnd,
            flags       : []
        )
        
        let uartBase = Kernel.platformInfo.uart.baseAddr
        try map(
            table       : table,
            virtual     : uartBase,
            physical    : uartBase,
            type        : .normal,
            flags       : [],
            defaultFlags: []
        )
        
        let gicDistributorBase  = Kernel.platformInfo.gic.gicdBase
        let gicCpuInterfaceBase = Kernel.platformInfo.gic.giccBase
        
        try map(
            table   : table,
            virtual : gicDistributorBase,
            physical: gicDistributorBase,
            type    : .normal,
            flags   : [],
            defaultFlags: []
        )
        
        try map(
            table   : table,
            virtual : gicCpuInterfaceBase,
            physical: gicCpuInterfaceBase,
            type    : .normal,
            flags   : [],
            defaultFlags: []
        )
    }
    
    private func mapKernelIdentitySpace(
        table: UnsafeMutablePointer<Arch.PageTableEntry>
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
        try map(
            table   : table,
            virtual : uartBase,
            physical: uartBase,
            type    : .device,
            flushTLB: false
        )

        let gicDistributorBase  = Kernel.platformInfo.gic.gicdBase
        let gicCpuInterfaceBase = Kernel.platformInfo.gic.giccBase
        
        try map(
            table   : table,
            virtual : gicDistributorBase,
            physical: gicDistributorBase,
            type    : .device,
            flushTLB: false
        )
        
        try map(
            table   : table,
            virtual : gicCpuInterfaceBase,
            physical: gicCpuInterfaceBase,
            type    : .device,
            flushTLB: false
        )
    }
    

    private func mapIdentitySection(
        table       : UnsafeMutablePointer<Arch.PageTableEntry>,
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
                flags   : flags,
                flushTLB: false
            )

            currentAddr += Self.pageSize
        }
    }
    
    private func mapUserRootSection(
        table       : UnsafeMutablePointer<Arch.PageTableEntry>,
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
                table       : table,
                virtual     : currentAddr,
                physical    : currentAddr,
                type        : type,
                flags       : flags,
                defaultFlags: []
            )
            
            currentAddr += Self.pageSize
        }
    }
}
