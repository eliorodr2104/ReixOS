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

    /// First mappable user VA. The page at `0x0` is reserved to trap
    /// NULL dereferences as translation faults.
    public static let userMin: VirtualAddress = 0x0000_0000_0000_1000

    /// Last mappable user VA (exclusive upper bound). Sits just below
    /// the 48-bit TTBR0 ceiling.
    public static let userMax: VirtualAddress = 0x0000_7FFF_FFFF_F000

    /// Default base used by user ELF binaries when linked with `user.ld`.
    public static let elfBaseTypical: VirtualAddress = 0x0000_0000_0040_0000

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
}
