//
//  MemoryFixtures.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.

@testable import Kernel

/// A host stand-in for RAM, with the bookkeeping the buddy allocator and the
/// physical page manager keep beside it.
///
/// Pair with `release()`, or let `withHostRAM` do both.
///
/// ## What is real and what is staged
///
/// Real: the `BuddyAllocator` over `base ..< base + size`, its bitmap and free
/// lists, the `FrameInfo` array, and any page tables `mapPage` builds.
///
/// Staged: the `KernelPPM` and the `VirtualMemoryManager`, allocated as zeroed
/// storage rather than run through their initializers, which both need a booted
/// machine (`Kernel.platformInfo`, the linker symbols, an MMU to enable). The
/// manager's `ramStart`, `ramSize` and `framesMetadata` are then pointed at this
/// arena, which is what makes `retain`, `release` and `refCount` operate on the
/// metadata below.
///
/// - Important: the staged manager's own allocator field stays zeroed, so **never
///   call `ppm.pointee.alloc`** on it: its free-list pointer is null and would be
///   dereferenced. Every other entry point is safe, because each one either
///   bounds-checks against `ramStart`/`ramSize` first or reaches the allocator only
///   through `BuddyAllocator.free`, which refuses an address outside its own
///   (zeroed) range instead of following a pointer. Use `buddy` directly to
///   exercise allocation, or `installLiveManager()` to replace the staged manager
///   with one that owns the real allocator.
public final class HostRAM {

    public static let pageSize: UInt64 = 4096

    /// Base of the stand-in RAM, and the `ramStart` the staged manager reports.
    public let base : PhysicalAddress
    public let size : UInt64
    public let pages: Int

    /// The real allocator over `base ..< base + size`. Nothing is donated to it
    /// until `donateAll` or `donate(from:to:)` is called.
    public let buddy: BuddyAllocator

    /// One `FrameInfo` per page of the arena, zeroed, which is the state every
    /// frame starts life with.
    public let frames: UnsafeMutablePointer<FrameInfo>

    public let ppm: UnsafeMutablePointer<KernelPPM>
    public let vmm: UnsafeMutablePointer<VirtualMemoryManager>

    /// Root of the user page tables `mapPage` fills in.
    public let rootTablePhysical: PhysicalAddress

    private let arena    : UnsafeMutableRawPointer
    private let bitmap   : UnsafeMutableRawPointer
    private let freeLists: UnsafeMutableRawPointer
    private var tables   : [UnsafeMutableRawPointer]
    private var released = false


    public init(pages: Int) {
        self.pages = pages
        self.size  = UInt64(pages) * Self.pageSize

        self.arena = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: Int(Self.pageSize)
        )
        arena.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))

        self.base = PhysicalAddress(UInt(bitPattern: arena))

        // Both walkers keep only bits [47:12] of an address, so an arena the host
        // placed above 256 TiB would be silently truncated.
        precondition(base & (Self.pageSize - 1) == 0, "host arena is not page aligned")
        Self.requireDescribable(base + size, "host arena")

        self.bitmap = UnsafeMutableRawPointer.allocate(
            byteCount: (pages + 7) / 8 + 8,
            alignment: 8
        )

        // 16 heads rather than the 12 orders the allocator has, so a raised
        // `BuddyAllocator.maxOrder` cannot run this buffer over.
        self.freeLists = UnsafeMutableRawPointer.allocate(
            byteCount: 16 * MemoryLayout<LinkedList<FreeBlock>>.stride,
            alignment: MemoryLayout<LinkedList<FreeBlock>>.alignment
        )

        self.buddy = BuddyAllocator(
            start           : base,
            size            : size,
            bitmapAddress   : PhysicalAddress(UInt(bitPattern: bitmap)),
            freeListsAddress: PhysicalAddress(UInt(bitPattern: freeLists))
        )

        let metadata = UnsafeMutableRawPointer.allocate(
            byteCount: pages * MemoryLayout<FrameInfo>.stride,
            alignment: MemoryLayout<FrameInfo>.alignment
        )
        self.frames = metadata.bindMemory(to: FrameInfo.self, capacity: pages)
        frames.initialize(repeating: FrameInfo(), count: pages)

        self.ppm = allocateZeroedStorage(KernelPPM.self)
        self.vmm = allocateZeroedStorage(VirtualMemoryManager.self)

        let root = UnsafeMutableRawPointer.allocate(
            byteCount: Int(Self.pageSize),
            alignment: Int(Self.pageSize)
        )
        root.initializeMemory(as: UInt8.self, repeating: 0, count: Int(Self.pageSize))

        self.rootTablePhysical = PhysicalAddress(UInt(bitPattern: root))
        self.tables            = [root]

        // A separate allocation from the arena, so it needs the bound of its own.
        Self.requireDescribable(rootTablePhysical, "root page table")

        ppm.pointee.framesMetadata = frames
        writeStoredProperty(base, at: \KernelPPM.ramStart)
        writeStoredProperty(size, at: \KernelPPM.ramSize)
        writeStoredProperty(UInt64(pages), at: \KernelPPM.totalPages)
    }


    /// Frees everything this arena owns. Idempotent, so a test may call it early.
    public func release() {
        guard !released else { return }
        released = true

        for table in tables { table.deallocate() }
        tables.removeAll()

        UnsafeMutableRawPointer(vmm).deallocate()
        UnsafeMutableRawPointer(ppm).deallocate()
        UnsafeMutableRawPointer(frames).deallocate()
        freeLists.deallocate()
        bitmap.deallocate()
        arena.deallocate()
    }


    /// One past the last byte of the arena, the address every bound here is
    /// exclusive of.
    public var end: PhysicalAddress { base + size }


    /// Physical address of page `index` of the arena.
    public func page(_ index: Int) -> PhysicalAddress {
        base + UInt64(index) * Self.pageSize
    }


    // MARK: - Allocator donations

    @discardableResult
    public func donateAll() -> Bool { donate(from: base, to: end) }


    @discardableResult
    public func donate(
        from start: PhysicalAddress,
        to   end  : PhysicalAddress
    ) -> Bool {
        do {
            try buddy.addFreeRange(from: start, to: end)
            return true

        } catch { return false }
    }


    // MARK: - Live manager

    /// Replaces the staged manager with one built through the host seam: the real
    /// `BuddyAllocator` over this arena as its allocator, this arena's bounds and
    /// `FrameInfo` array, and `deviceTree` recorded as the extent the boot sweep
    /// withheld for the blob.
    ///
    /// This is what lifts the `alloc` ban in the note above, and the only way a host
    /// process reaches `reclaimDeviceTree`'s donation path or the kernel heap: both
    /// need an allocator, and the field is `private`. See the host seam at the foot
    /// of `PhysicalPageManager.swift`.
    ///
    /// Nothing is donated to the allocator here, so the caller still decides which
    /// frames the buddy owns. A reclaim test needs that: the point of the exercise is
    /// that the extent's frames were *not* the allocator's until the reclaim ran.
    ///
    /// - Precondition: a `deviceTree` extent must be page aligned, inside this arena
    ///   and already withheld, so `markReserved(from:to:)` comes first and this call
    ///   second. The seam checks all three and traps rather than letting a reclaim
    ///   donate frames the allocator already holds.
    public func installLiveManager(
        deviceTree: (start: PhysicalAddress, end: PhysicalAddress)? = nil
    ) {
        ppm.pointee = KernelPPM(
            hostAllocator : buddy,
            ramStart      : base,
            ramSize       : size,
            framesMetadata: frames,
            deviceTree    : deviceTree
        )
    }


    /// Marks `from ..< to` as frames a boot block withheld, the shape the sweep
    /// leaves behind: one reference each and the `reserved` flag.
    public func markReserved(
        from start: PhysicalAddress,
        to   end  : PhysicalAddress
    ) {
        var address = start
        while address < end {
            setFrame(FrameInfo(refCount: 1, order: 0, flags: .reserved), at: address)
            address += Self.pageSize
        }
    }


    // MARK: - Frame metadata

    public func frame(at physical: PhysicalAddress) -> FrameInfo {
        frames[frameIndex(of: physical)]
    }


    public func setFrame(
        _  info    : FrameInfo,
        at physical: PhysicalAddress
    ) {
        frames[frameIndex(of: physical)] = info
    }


    /// Marks `physical` as an owned order-0 frame carrying `refCount` references,
    /// the shape `PhysicalPageManager.release` expects of a block head.
    public func setOwnedFrame(
        at physical: PhysicalAddress,
        refCount   : UInt32
    ) {
        setFrame(
            FrameInfo(refCount: refCount, order: 0, flags: .none),
            at: physical
        )
    }


    public func frameIndex(of physical: PhysicalAddress) -> Int {
        Int((physical - base) / Self.pageSize)
    }


    // MARK: - Page tables

    /// Maps `virtual` onto `physical` as a user page, creating whatever levels of
    /// the walk are missing.
    ///
    /// Written here rather than driven through `VirtualMemoryManager.mapUserPage`
    /// because that one allocates its intermediate tables from the physical page
    /// manager, which is exactly the entry point a staged manager cannot serve.
    /// The descriptors are the same ones `map` writes.
    public func mapPage(
        virtual : VirtualAddress,
        physical: PhysicalAddress
    ) {
        var table = descend(from: rootTable, index: virtual.l0)
        table     = descend(from: table,     index: virtual.l1)
        table     = descend(from: table,     index: virtual.l2)

        var entry = Arch.PageTableEntry(rawValue: 0)
        entry.physicalAddress = physical
        entry.flags           = [.valid, .page, .accessFlag, .userAccess, .notGlobal]

        table[virtual.l3] = entry
    }


    /// What the kernel's own walker resolves `virtual` to, or `nil` when nothing
    /// maps it.
    public func translate(_ virtual: VirtualAddress) -> PhysicalAddress? {
        vmm.pointee.physicalAddressOf(
            rootTable: rootTablePhysical,
            virtual  : virtual
        )
    }


    private var rootTable: UnsafeMutablePointer<Arch.PageTableEntry> {
        UnsafeMutableRawPointer(bitPattern: UInt(rootTablePhysical))!
            .bindMemory(to: Arch.PageTableEntry.self, capacity: 512)
    }


    private func descend(
        from  table: UnsafeMutablePointer<Arch.PageTableEntry>,
        index      : Int
    ) -> UnsafeMutablePointer<Arch.PageTableEntry> {

        if table[index].isPresent {
            return UnsafeMutableRawPointer(bitPattern: UInt(table[index].physicalAddress))!
                .bindMemory(to: Arch.PageTableEntry.self, capacity: 512)
        }

        let next = UnsafeMutableRawPointer.allocate(
            byteCount: Int(Self.pageSize),
            alignment: Int(Self.pageSize)
        )
        next.initializeMemory(as: UInt8.self, repeating: 0, count: Int(Self.pageSize))
        tables.append(next)

        // Its address goes into a descriptor, which keeps bits [47:12] and nothing
        // above them: a truncated table would fail as an unresolvable address.
        Self.requireDescribable(PhysicalAddress(UInt(bitPattern: next)), "page table")

        var entry = Arch.PageTableEntry(rawValue: 0)
        entry.physicalAddress = PhysicalAddress(UInt(bitPattern: next))
        entry.flags           = [.valid, .page]

        table[index] = entry

        return next.bindMemory(to: Arch.PageTableEntry.self, capacity: 512)
    }


    // MARK: - Staged storage

    /// Halts unless `address` survives a descriptor, which keeps bits [47:12].
    ///
    /// Every allocation this class hands to the kernel's walkers goes through here:
    /// the arena, the root table and each intermediate table are separate host
    /// allocations, and one of them placed above 256 TiB would be truncated where
    /// it is written rather than where it is read. That failure looks like an
    /// address the walker cannot resolve, which is a long way from its cause.
    private static func requireDescribable(
        _ address: PhysicalAddress,
        _ what   : StaticString
    ) {
        precondition(
            address < (1 << 48),
            "\(what) sits above the 48-bit range a page table descriptor can hold"
        )
    }

    /// Writes `value` over a stored property of the staged manager.
    ///
    /// `ramStart` and `ramSize` are `let`s set by an initializer no host process
    /// can run, and the manager's memberwise initializer is private because one of
    /// its fields is. The bytes are reachable all the same: `MemoryLayout.offset`
    /// answers where a stored property lives, and the storage below was allocated
    /// and zeroed by this class, never handed out as a value anyone could have
    /// copied. Nothing in `Sources` is bent to make this work.
    ///
    /// The key path is typed rather than partial, so `Value` is the property's own
    /// type and cannot be told apart from it by the caller. With a
    /// `PartialKeyPath` a field narrowed in `Sources`, `totalPages` becoming a
    /// `UInt32`, would still compile here and store eight bytes into a four-byte
    /// slot, silently overwriting whatever follows it.
    private func writeStoredProperty<Value>(
        _  value  : Value,
        at keyPath: KeyPath<KernelPPM, Value>
    ) {
        guard let offset = MemoryLayout<KernelPPM>.offset(of: keyPath) else {
            fatalError("HostRAM: \(keyPath) is not stored inline in KernelPPM")
        }

        UnsafeMutableRawPointer(ppm).storeBytes(
            of         : value,
            toByteOffset: offset,
            as         : Value.self
        )
    }
}


/// Runs `body` over one `HostRAM` of `pages` pages, then releases it.
public func withHostRAM(
    pages : Int,
    _ body: (HostRAM) -> Void
) {
    let ram = HostRAM(pages: pages)
    body(ram)
    ram.release()
}


/// Storage for `T` that is all zero bytes and was never run through an
/// initializer, for the collaborators whose real `init` needs a booted machine.
///
/// Both types used with it are plain data (integers, option sets and unsafe
/// pointers), so zero is a value they can hold and no reference count is
/// fabricated by writing it.
public func allocateZeroedStorage<T>(_ type: T.Type) -> UnsafeMutablePointer<T> {
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<T>.stride,
        alignment: MemoryLayout<T>.alignment
    )
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.stride)

    return storage.bindMemory(to: T.self, capacity: 1)
}
