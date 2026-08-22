//
//  VirtualMemoryManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct VirtualMemoryManager: Loggable {
    
    public static let nameLog : StaticString = "[VMM ]"
    public static let logLevel: LogLevel     = .info

    private let ppmPtr              : UnsafeMutablePointer<KernelPPM>
        
    /// Root (TTBR1 - Address 0xFFFF...)
    private let kernelRootTable     : UnsafeMutablePointer<Arch.PageTableEntry>
    
    /// Root Temp (TTBR0 - Address 0x0000...)
    private let identityRootTable   : UnsafeMutablePointer<Arch.PageTableEntry>
    
    private let kernelTableAddress  : PhysicalAddress
    private let identityTableAddress: PhysicalAddress
    
    static let physicalOffset       : UInt64 = 0xFFFF800000000000
    static let pageSize             : UInt64 = 4096

    /// Span of a level-2 block descriptor with the 4 KiB granule.
    ///
    /// The linear map is the one region that fits a block exactly: contiguous,
    /// aligned and uniformly attributed. Paying an L3 table for every 2 MiB of
    /// it costs `RAM / 256` bytes twice over, once per root. On a 4 MiB machine
    /// that is the difference between the mapping fitting and not.
    ///
    /// Level 1 (1 GiB) is deliberately not used: RAM here never spans a whole
    /// aligned gigabyte, and a block that large would also map the hole above
    /// RAM inside the same L1 slot as cacheable normal memory.
    static let blockSize            : UInt64 = 2 * 1024 * 1024

    /// Largest physical address the high-half window can name.
    ///
    /// Every translation into that window is `physicalOffset + physical`, so
    /// anything past this wraps. Note how tight the bound is: the window
    /// starts at `0xFFFF_8000_0000_0000`, which leaves exactly 47 bits, and
    /// "below `physicalOffset`" is *not* the same test, `0x8000_0000_0000`
    /// satisfies it and still overflows.
    ///
    /// The addresses that reach it come from the device tree, so the check
    /// belongs wherever one is first believed. Under `-Osize` the overflow
    /// check is live, and the add happens in early boot before anything can
    /// report it: a bad base folds the machine silently instead of saying why.
    static let maxPhysicalAddress: UInt64 = UInt64.max - physicalOffset

    /// Monotonically increasing ASID source for newly created address spaces.
    /// Wraps to `1` (skipping `0`, reserved for the kernel TTBR1 space) and
    /// flushes the TLB on wrap to avoid stale tagged entries.
    private var asidCounter         : ASID = 1
    
    
    #if !hasFeature(Embedded)
    /// Host stand-in for a manager the real initialiser cannot build off the
    /// machine, seamed like `PPMBackend.physicalOffset`: `hasFeature(Embedded)`
    /// is on only when `Package.swift` sees `FREESTANDING=1`, so the machine is
    /// compiled without this at all.
    ///
    /// The real `init` maps the linker's sections and then panics unless the
    /// stack guard page sits exactly between `_kernel_end` and `__stack_bottom`.
    /// Off the machine those are four unrelated bytes in `KernelHostShims.c`,
    /// which no arithmetic can make satisfy it, and that wall is why
    /// `ELFLoaderFixtures` runs the loader against a zeroed manager instead.
    ///
    /// This takes the two fields `createAddressSpace` actually reads and leaves
    /// the mapping machinery alone, so a suite can exercise the address-space
    /// lifecycle without a booted machine. `physToVirt` is already the identity
    /// here, because `isMMUEnabled()` is a shim that answers false, so an arena
    /// address doubles as its own pointer.
    ///
    /// - Parameter identityTable: a zeroed, readable 512-entry page. Its
    ///   descriptors are what `createAddressSpace` copies into every new root,
    ///   so leaving them zero is what makes a fresh address space empty.
    init(
        hostPPM      : UnsafeMutablePointer<KernelPPM>,
        identityTable: PhysicalAddress
    ) {
        self.ppmPtr               = hostPPM
        self.kernelTableAddress   = identityTable
        self.identityTableAddress = identityTable
        self.kernelRootTable      = UnsafeMutablePointer(bitPattern: UInt(identityTable))!
        self.identityRootTable    = UnsafeMutablePointer(bitPattern: UInt(identityTable))!
    }
    #endif


    public func physToVirt<T>(_ phys: UInt64) -> UnsafeMutablePointer<T> {
        let offset = Arch.MMU.isMMUEnabled() ? Self.physicalOffset : 0
        let virtAddr = phys + offset
        return UnsafeMutablePointer<T>(bitPattern: UInt(virtAddr))!
    }
    
    /// Build both translation roots, then enable the MMU on them.
    ///
    /// The order the sections are issued in is load-bearing. The kernel image
    /// and the initrd are mapped first with their own permissions, and the
    /// linear map that follows covers whatever is left of RAM. It must not run
    /// over the top of them: a descriptor keeps whatever was written to it
    /// last, so a linear map spanning the initrd silently replaces the
    /// read-only mapping with a writable one, in both roots. The linear map is
    /// therefore issued as two spans with the initrd's page-aligned extent cut
    /// out between them.
    ///
    /// The hole costs nothing in page tables. Mapping the initrd at 4 KiB
    /// already forces an L3 table into every 2 MiB span it touches, and
    /// `canInstallBlock` already refuses a block over a span that is paged, so
    /// those spans were being written page by page either way. Only the flags
    /// that land in the descriptors change.
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
            endAddress  : initrdEnd,
            type        : .normal,
            flags       : [.present, .readOnly, .pxn]
        )

        flags = [.present, .pxn]
        let ramEnd = PhysicalAddress(self.ppmPtr.pointee.ramStart + self.ppmPtr.pointee.ramSize)

        let guardBottom = getOfaddressWithSymbol(of: &__stack_guard_bottom)
        let guardTop    = getOfaddressWithSymbol(of: &__stack_guard_top)

        // The guard page only guards while it is exactly the span between the
        // last page of the kernel image and the bottom of the stack.
        guard guardBottom == (kernelEnd + (Self.pageSize - 1)) & ~(Self.pageSize - 1),
              guardTop    == guardBottom + Self.pageSize
        else {
            Arch.CPU.panic("the stack guard page is not between _kernel_end and __stack_bottom")
        }

        // Starts above the guard page, not above `_kernel_end`: the linear map
        // covers RAM, so leaving the guard out of it is what makes it fault.
        let safeRamStart = guardTop

        // Rounded the same way `mapSection` rounds its own bounds, so the hole
        // covers exactly the pages the read-only mapping above touched.
        let initrdFirstPage = initrdBase & ~(Self.pageSize - 1)
        let initrdLastPage  = (initrdEnd + (Self.pageSize - 1)) & ~(Self.pageSize - 1)

        let initrdInLinearMap = initrdEnd       > initrdBase
                             && initrdLastPage  > safeRamStart
                             && initrdFirstPage < ramEnd

        // Collapsed onto `ramEnd` when there is no initrd to skip: the first
        // span then covers all of RAM and the second one is empty.
        let holeStart = initrdInLinearMap ? max(initrdFirstPage, safeRamStart) : ramEnd
        let holeEnd   = initrdInLinearMap ? min(initrdLastPage,  ramEnd)       : ramEnd

        try mapSection(
            startAddress: safeRamStart,
            endAddress  : holeStart,
            flags       : flags
        )

        try mapSection(
            startAddress: holeEnd,
            endAddress  : ramEnd,
            flags       : flags
        )

        let uartBase            = Kernel.platformInfo.uart.baseAddr
        let gicDistributorBase  = Kernel.platformInfo.gic.gicdBase
        let gicCpuInterfaceBase = Kernel.platformInfo.gic.giccBase

        guard uartBase            <= Self.maxPhysicalAddress,
              gicDistributorBase  <= Self.maxPhysicalAddress,
              gicCpuInterfaceBase <= Self.maxPhysicalAddress else {
            Arch.CPU.panic("MMIO base from the device tree cannot be mapped into the high half")
        }

        try map(table: identityRootTable, virtual: uartBase, physical: uartBase, type: .device)
        try map(table: kernelRootTable, virtual: Self.physicalOffset + uartBase, physical: uartBase, type: .device)
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

        Self.boot("Virtual Memory Manager ready.")
    }


    public mutating func createAddressSpace() throws(PPMError) -> AddressSpace {
        let page = try ppmPtr.pointee.alloc(4096, flag: .kernel)
        let rootTable: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(page.address)
        rootTable.initialize(repeating: Arch.PageTableEntry(rawValue: 0), count: 512)

        let kernelMaster: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(self.identityTableAddress)
        for index in 0..<512 where kernelMaster[index].isPresent {
            rootTable[index] = kernelMaster[index]
        }

        let asid = self.asidCounter

        self.asidCounter = self.asidCounter &+ 1
        if self.asidCounter == 0 {
            self.asidCounter = 1
            Arch.MMU.flushTLB()
        }

        return AddressSpace(
            rootTablePhysical: page.address,
            asid             : asid,
            vmaManager       : nil
        )
    }


    public func destroyAddressSpace(addressSpace: consuming AddressSpace) throws(PPMError) {
        
        Arch.MMU.switchUserAddressSpace(self.identityTableAddress, asid: 0)
        Arch.MMU.flushTLB()

        freePageTables(rootTable: addressSpace.rootTablePhysical)

        try ppmPtr.pointee.freeOwnedKernelPage(
            PhysicalPage(address: addressSpace.rootTablePhysical, order: 0)
        )

        Arch.MMU.flushTLB()
    }


    /// Free the intermediate page-table pages of an address space, depth-first.
    /// Walks the L0 root and recurses through table descriptors only; the L0
    /// root page itself is freed by the caller. Leaf (block/page) descriptors
    /// point at data frames owned elsewhere and are deliberately left alone.
    private func freePageTables(rootTable: PhysicalAddress) {
        let l0: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)
        let kernelMaster: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(self.identityTableAddress)

        for index in 0..<512 {
            let entry = l0[index]
            guard entry.isPresent, entry.isTableDescriptor else { continue }

            if entry.physicalAddress == kernelMaster[index].physicalAddress { continue }

            freePageTableSubtree(tablePhysical: entry.physicalAddress, level: 1)
        }
    }

    /// Free the subtree rooted at a level-`level` table (1 = L1, 2 = L2,
    /// 3 = L3), then the table page itself. Each table page is fully read
    /// before it is released, so the post-free overwrite the PPM performs on a
    /// reclaimed block never races the walk.
    private func freePageTableSubtree(
        tablePhysical: PhysicalAddress,
        level        : Int
    ) {
            
        if level < 3 {
            let table: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(tablePhysical)
            
            for index in 0..<512 {
                let entry = table[index]
                guard entry.isPresent, entry.isTableDescriptor else { continue }
                
                freePageTableSubtree(
                    tablePhysical: entry.physicalAddress,
                    level        : level + 1
                )
            }
        }

        try? ppmPtr.pointee.freeOwnedKernelPage(
            PhysicalPage(address: tablePhysical, order: 0)
        )
    }


    public func mapUserPage(
        rootTable: PhysicalAddress,
        virtual  : VirtualAddress,
        physical : PhysicalAddress,
        flags    : VirtualPageFlags,
        type     : MemoryType        = .normal
    ) throws(PPMError) {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)
        
        try map(
            table   : tablePointer,
            virtual : virtual,
            physical: physical,
            type    : type,
            flags   : flags.union([.notGlobal])
        )
    }
    
    
    public func protectUserPage(
        rootTable: PhysicalAddress,
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
        flags       : VirtualPageFlags
    ) throws(PPMError) {
        let rootTable = addressSpace.rootTablePhysical
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)

        try map(
            table   : tablePointer,
            virtual : virtual,
            physical: physical,
            type    : .normal,
            flags   : flags.union([.notGlobal])
        )
    }
    

    public func unmapUserPage(
        rootTable: PhysicalAddress,
        virtual  : VirtualAddress
    ) throws(PPMError) {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)
        guard let leafTable = lookupLeafTable(table: tablePointer, virtual: virtual) else {
            return
        }

        leafTable[virtual.l3] = Arch.PageTableEntry(rawValue: 0)

        Arch.MMU.pageTableBarrier()
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


    /// The L3 table covering `virtual`, or `nil` when no table is installed for
    /// its 2 MiB span.
    ///
    /// Exposed so bulk walkers can amortise the descent instead of calling
    /// `physicalAddressOf` per page: the L0/L1/L2 indexes are identical for
    /// every address inside one L3 table's span, so a caller stepping through a
    /// range resolves them once and then reads `leaf[va.l3]` directly. A `nil`
    /// result means the entire span is unmapped and can be skipped whole; the
    /// common case for the sparse `noReserve` and `growDown` regions, which
    /// reserve megabytes and keep only a handful of pages resident.
    ///
    /// The returned pointer stays valid as long as no level above L3 is torn
    /// down for that span, which no caller does mid-walk.
    public func leafTable(
        rootTable: PhysicalAddress,
        virtual  : VirtualAddress
    ) -> UnsafeMutablePointer<Arch.PageTableEntry>? {
        let tablePointer: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)

        return lookupLeafTable(table: tablePointer, virtual: virtual)
    }


    /// Resolve `virtual` in `rootTable`, terminating on whichever descriptor
    /// actually maps it.
    ///
    /// Written as its own descent rather than on top of `lookupLeafTable`
    /// because that helper can only ever hand back an L3 table, and the linear
    /// map no longer ends at L3: a kernel-window address inside a 2 MiB block
    /// would resolve to `nil`, a mapped address reported as unmapped, which
    /// every caller reads as "nothing to do".
    public func physicalAddressOf(
        rootTable: PhysicalAddress,
        virtual  : VirtualAddress
    ) -> PhysicalAddress? {

        var currentTable: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(rootTable)

        let indexes: InlineArray<3, Int> = [virtual.l0, virtual.l1, virtual.l2]
        let shifts : InlineArray<3, Int> = [39, 30, 21]

        for i in 0..<indexes.count {
            let entry = currentTable[indexes[i]]
            guard entry.isPresent else { return nil }

            if !entry.isTableDescriptor {
                // Block: the descriptor carries the block base, the low bits of
                // the virtual address carry the offset into it.
                let offsetMask = (UInt64(1) << UInt64(shifts[i])) - 1

                return (entry.physicalAddress & ~offsetMask) | (virtual & offsetMask)
            }

            currentTable = physToVirt(entry.physicalAddress)
        }

        let entry = currentTable[virtual.l3]
        guard entry.isPresent else { return nil }

        return entry.physicalAddress
    }


    // MARK: - Internals Handlers
    
    private func map(
        table       : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual     : VirtualAddress,
        physical    : PhysicalAddress,
        type        : MemoryType,
        flags       : VirtualPageFlags = [.present],
        defaultFlags: VirtualPageFlags = [.valid, .page, .accessFlag]
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

        Arch.MMU.pageTableBarrier()
    }

    /// Install a 2 MiB block descriptor at level 2.
    ///
    /// Only bit 1 separates a block from a table at L1/L2. The MAIR index, AP,
    /// SH, AF, nG and PXN/UXN all sit in the same bits as in an L3 page
    /// descriptor, so the caller's flags carry over untouched and only `.page`
    /// has to come back out. Getting that one bit wrong does not fault: the
    /// walker would follow the block's output address as if it were the next
    /// table and read RAM as descriptors.
    private func mapBlock(
        table   : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual : VirtualAddress,
        physical: PhysicalAddress,
        type    : MemoryType,
        flags   : VirtualPageFlags
    ) throws(PPMError) {

        var currentTable = table
        currentTable = try mapTable(current: currentTable, virtual.l0)
        currentTable = try mapTable(current: currentTable, virtual.l1)

        var entry = currentTable[virtual.l2]
        entry.physicalAddress = physical

        let attrs = type.attributes
        entry.mairIndex    = attrs.mair
        entry.shareability = attrs.share
        entry.flags        = flags.union([.valid, .accessFlag]).subtracting(.page)

        currentTable[virtual.l2] = entry

        Arch.MMU.pageTableBarrier()
    }


    /// Whether a 2 MiB block may replace the L2 entry covering `virtual`.
    ///
    /// A block replaces that entry outright, so an L3 table already sitting
    /// there would be orphaned together with every 4 KiB mapping inside it.
    /// The kernel image and the initrd are mapped page by page before the
    /// linear map runs and both live inside RAM, so their 2 MiB spans have to
    /// stay paged. Anything else is fine: an absent level, or a block being
    /// re-written.
    private func canInstallBlock(
        table  : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual: VirtualAddress
    ) -> Bool {
        let level0 = table[virtual.l0]
        guard level0.isPresent        else { return true  }
        guard level0.isTableDescriptor else { return false }

        let level1Table: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(level0.physicalAddress)
        let level1 = level1Table[virtual.l1]
        guard level1.isPresent         else { return true  }
        guard level1.isTableDescriptor else { return false }

        let level2Table: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(level1.physicalAddress)

        return !level2Table[virtual.l2].isTableDescriptor
    }


    /// The next-level table under `current[index]`, allocated and zeroed when
    /// the entry is absent.
    ///
    /// A present non-table entry there is a 2 MiB block, and descending into it
    /// would hand back a slab of mapped RAM to be written as if it were 512
    /// descriptors. Nothing in the kernel is supposed to page a span the linear
    /// map already blocked, so this halts instead of corrupting it silently.
    private func mapTable(
        current: UnsafeMutablePointer<Arch.PageTableEntry>,
        _ index: Int
    ) throws(PPMError) -> UnsafeMutablePointer<Arch.PageTableEntry> {
        var entry = current[index]

        if entry.isPresent, !entry.isTableDescriptor {
            Arch.CPU.panic("page-table walk hit a block descriptor where a table was required")
        }

        if !entry.isPresent {
            let newPage = try ppmPtr.pointee.alloc(4096, flag: .kernel)

            let newTablePtr: UnsafeMutablePointer<Arch.PageTableEntry> = physToVirt(newPage.address)
            
            newTablePtr.initialize(
                repeating: Arch.PageTableEntry(rawValue: 0),
                count    : 512
            )

            Arch.MMU.pageTableBarrier()

            entry.physicalAddress = newPage.address
            entry.flags = [.valid, .page]
            current[index] = entry
        }
        
        return physToVirt(entry.physicalAddress)
    }

    /// Descend to the L3 table covering `virtual`, without creating anything.
    ///
    /// The `isTableDescriptor` test is what stops the descent at a 2 MiB block:
    /// there is no L3 table under one, and following its output address would
    /// reinterpret mapped RAM as descriptors. Callers that must resolve an
    /// address inside a block go through `physicalAddressOf`, which terminates
    /// on the block instead.
    private func lookupLeafTable(
        table  : UnsafeMutablePointer<Arch.PageTableEntry>,
        virtual: VirtualAddress
    ) -> UnsafeMutablePointer<Arch.PageTableEntry>? {
        var currentTable = table

        let indexes: InlineArray<3, Int> = [virtual.l0, virtual.l1, virtual.l2]

        for i in 0..<indexes.count {
            let index = indexes[i]
            let entry = currentTable[index]

            guard entry.isPresent, entry.isTableDescriptor else { return nil }

            currentTable = physToVirt(entry.physicalAddress)
        }

        return currentTable
    }
    
    /// Map `[startAddress, endAddress)` identically in the low root and at
    /// `physicalOffset` in the high root, in 2 MiB blocks where one fits and
    /// 4 KiB pages otherwise.
    ///
    /// A block is taken only when the span is whole and aligned in both roots
    /// and neither of them already pages it. `physicalOffset` is 2 MiB aligned,
    /// so the two roots agree on alignment by construction; requiring them to
    /// agree on the fallback too keeps the identity and high-half views
    /// structurally identical, which is what every walker here assumes.
    ///
    /// Note that a span already mapped page by page stays paged, and that a
    /// later call over the same addresses overwrites the earlier flags. Ranges
    /// mapped with permissions of their own have to be excluded by the caller,
    /// not relied on to survive.
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
            let highAddr = Self.physicalOffset + currentAddr

            let blockFits = currentAddr & (Self.blockSize - 1) == 0
                         && alignedEnd - currentAddr >= Self.blockSize
                         && canInstallBlock(table: identityRootTable, virtual: currentAddr)
                         && canInstallBlock(table: kernelRootTable,   virtual: highAddr)

            if blockFits {
                try mapBlock(
                    table   : identityRootTable,
                    virtual : currentAddr,
                    physical: currentAddr,
                    type    : type,
                    flags   : flags
                )

                try mapBlock(
                    table   : kernelRootTable,
                    virtual : highAddr,
                    physical: currentAddr,
                    type    : type,
                    flags   : flags
                )

                currentAddr += Self.blockSize
                continue
            }

            try map(
                table   : identityRootTable,
                virtual : currentAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )

            try map(
                table   : kernelRootTable,
                virtual : highAddr,
                physical: currentAddr,
                type    : type,
                flags   : flags
            )

            currentAddr += Self.pageSize
        }
    }

}
