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
/// into three macro-regions:
///
///
/// The numeric values target a 48-bit user VA (ARMv8.0-A baseline) and
/// keep the lowest 4 KiB unmapped to trap NULL-derived accesses.
public enum UserSpaceLayout {

    /// Granule shared with the MMU and the PPM allocator.
    public static let pageSize: UInt64 = 4096

    /// First mappable user VA — the start of L0 entry 1 (512 GiB).
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
    /// from this anchor (enabled in step 5b).
    public static let mmapBase: VirtualAddress = 0x0000_4000_0000_0000

    /// Lower bound the mmap area may consume. Picked far above any
    /// plausible ELF base + brk heap so collisions only happen for
    /// pathologically large processes.
    public static let mmapMin: VirtualAddress = 0x0000_2000_0000_0000

    /// Top of the initial user stack. The first stack page sits at
    /// `stackTop - pageSize`.
    public static let stackTop: VirtualAddress = 0x0000_7FFF_FFFE_0000

    /// Lower bound the user stack is allowed to grow down to. Anything
    /// below `stackLimit` belongs to the guard area or to the mmap
    /// region.
    public static let stackLimit: VirtualAddress = 0x0000_7FFE_0000_0000

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
