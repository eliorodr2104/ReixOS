//
//  UserSpaceLayout.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Per-process virtual address space layout.
///
/// All constants live here to avoid scattering magic numbers across
/// loaders, syscalls and the VMA manager. The layout splits user space
/// into three macro-regions: the ELF image, the mmap area and the stack.
///
/// The numeric values target a 48-bit user VA (ARMv8.0-A baseline) and
/// keep the lowest 4 KiB unmapped to trap NULL-derived accesses.
///
/// ## Why everything lives inside one gigabyte
///
/// The regions used to be spread across the 128 TiB of TTBR0 (image at
/// L0[1], mmap at L0[64] and L0[128], stack at L0[255]), which reads well and
/// costs three page-table levels *per region*, because two addresses share a
/// table only when they share every index above it. A process that mapped
/// nothing but its image and its stack still paid 7 pages: the root, then
/// L1/L2/L3 twice over.
///
/// Everything now sits inside the first gigabyte of L0[1], so `l0` is 1 and
/// `l1` is 0 for every user address. One L1 table and one L2 table serve the
/// whole address space and each region adds only its own L3 table. The same
/// process now pays 5 pages, and a shared-memory window costs one page rather
/// than three.
///
/// What that buys is spare virtual address space, of which there was 128 TiB
/// and no use for it: the largest window here is still two orders of magnitude
/// past the RAM of the machines this targets. The windows below are laid out
/// so the guard page, the mmap area and the stack cannot meet (see each
/// constant), and `VMAManager` rejects an overlap regardless.
public enum UserSpaceLayout {

    /// Granule shared with the MMU and the PPM allocator.
    public static let pageSize: UInt64 = 4096

    /// First mappable user VA: the start of L0 entry 1 (512 GiB).
    ///
    /// The whole L0[0] subtree (VAs below 512 GiB) is reserved for the kernel:
    /// every address space shares the kernel's single L0[0] entry by reference
    /// (see `VMM.createAddressSpace`), so user mappings must never fall inside
    /// it or they would corrupt the page tables of every process. Confining
    /// user space to L0[1..255] keeps user and kernel in disjoint top-level
    /// entries. Everything below 512 GiB (incl. `0x0`) is therefore unmapped
    /// for user space, so NULL-derived accesses still trap.
    public static let userMin: VirtualAddress = 0x0000_0080_0000_0000

    /// Last mappable user VA (exclusive upper bound). Sits just below
    /// the 48-bit TTBR0 ceiling.
    public static let userMax: VirtualAddress = 0x0000_7FFF_FFFF_F000

    /// Default base used by user ELF binaries when linked with `user.ld`.
    /// Sits 4 MiB into L0 entry 1 (512 GiB), leaving the bottom of the user
    /// region as a guard and keeping the ELF image clear of `userMin`.
    public static let elfBaseTypical: VirtualAddress = 0x0000_0080_0040_0000

    /// Top of the mmap allocation area. mmap allocations grow downward
    /// from this anchor.
    ///
    /// Deliberately below the stack guard page rather than adjacent to it: the
    /// gap means an mmap region can never be handed the address the stack
    /// overflow check relies on being unmapped.
    public static let mmapBase: VirtualAddress = 0x0000_0080_3B00_0000

    /// Lower bound the mmap area may consume, and, via `extendBreak`, the
    /// ceiling of the brk heap. Leaves the heap ~508 MiB above the ELF base
    /// and the mmap area ~432 MiB, both far past what a machine sized for this
    /// kernel can back with frames.
    public static let mmapMin: VirtualAddress = 0x0000_0080_2000_0000

    /// Top of the initial user stack. The first stack page sits at
    /// `stackTop - pageSize`.
    ///
    /// Kept below `0x80_4000_0000`, the end of the first gigabyte of L0[1], so
    /// the stack shares its L1 and L2 tables with the image instead of
    /// building three levels of its own.
    public static let stackTop: VirtualAddress = 0x0000_0080_3FFF_E000

    /// Lower bound the user stack is allowed to grow down to. Anything
    /// below `stackLimit` belongs to the guard area or to the mmap
    /// region.
    ///
    /// 64 MiB of growth. That is a hard ceiling where the old layout had 8 GiB
    /// of unusable slack. The machines this targets have single-digit
    /// megabytes of RAM, so the stack runs out of frames long before it runs
    /// out of addresses.
    public static let stackLimit: VirtualAddress = 0x0000_0080_3C00_0000

    /// Number of guard pages reserved just below `stackLimit`. Touching
    /// a guard page raises a permission fault that the kernel turns into
    /// a deterministic stack-overflow segfault.
    public static let guardPageCount: Int = 1
    
    public static func checkedUserRange(
        address: UInt64,
        size   : UInt64
    ) -> (start: UInt64, end: UInt64)? {
        
        guard size > 0,
              address >= userMin,
              address <= userMax, size <= userMax - address else {
            return nil
        }
        return (address, address + size)
    }
    
    public static func checkedPageRange(
        address: UInt64,
        size   : UInt64
    ) -> (start: VirtualAddress, end: VirtualAddress)? {
        
        guard let range = Self.checkedUserRange(address: address, size: size) else {
            return nil
        }
 
        let start = range.start & ~(Self.pageSize - 1)
        let end   = (range.end + Self.pageSize - 1) & ~(Self.pageSize - 1)
        
        return (start, end)
     }
}
