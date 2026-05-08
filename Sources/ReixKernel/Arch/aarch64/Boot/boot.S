//
//  boot.s
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

.equ SPSR_EL1h,  (0b0101)
.equ SPSR_DAIF,  (0b1111 << 6)
.equ SPSR_VALUE, (SPSR_EL1h | SPSR_DAIF)   // 0x3C5
.equ KERNEL_VIRT_OFFSET, 0xFFFF800000000000

.section .text.boot
.global _start

_start:
    mov     x21, x0
    
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbz     x0, .L_master_core

.L_parking_loop:
    wfe
    b       .L_parking_loop

.L_master_core:
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.eq    .L_drop_to_el1
    b       .L_setup_el1

.L_drop_to_el1:
    msr     cptr_el2, xzr
    
    mov     x0, #0x3
    msr     cnthctl_el2, x0
    
    msr     cntvoff_el2, xzr

    mov     x0, #(1 << 31)
    msr     hcr_el2, x0

    ldr     x0, =SPSR_VALUE
    msr     spsr_el2, x0

    adr     x1, .L_setup_el1
    msr     elr_el2, x1
    eret

.L_setup_el1:
    // Set up a temporary stack (physical address pre-MMU).
    adrp    x0, stack_top
    add     x0, x0, :lo12:stack_top
    mov     sp, x0

    // Set early exception vectors (physical address pre-MMU).
    adrp    x0, _evt_start
    add     x0, x0, :lo12:_evt_start
    msr     vbar_el1, x0
    
    mrs     x0, cntkctl_el1
    orr     x0, x0, #0x3
    msr     cntkctl_el1, x0

    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    ldr     x2, =__bss_start
    ldr     x3, =__bss_end
    // When linked in higher-half, these symbols are virtual addresses.
    // Pre-MMU we must clear the physical range, so subtract the fixed offset.
    ldr     x4, =KERNEL_VIRT_OFFSET
    sub     x2, x2, x4
    sub     x3, x3, x4

.L_bss_loop:
    cmp     x2, x3
    b.hs    .L_setup_boot_mmu
    str     xzr, [x2], #8
    b       .L_bss_loop

.L_setup_boot_mmu:
    // Set up temporary identity + higher-half page tables and enable the MMU.
    bl      boot_enable_mmu

    // Switch stack into the higher-half direct map (TTBR1).
    ldr     x0, =KERNEL_VIRT_OFFSET
    add     sp, sp, x0

    // Update VBAR into the higher-half mapping.
    ldr     x1, =_evt_start
    msr     vbar_el1, x1

    // Jump to the higher-half entry point.
    ldr     x2, =.L_jump_to_swift_high
    br      x2

.L_jump_to_swift_high:
    mov     x29, #0
    mov     x30, #0
    mov     x0, x21
    bl      kernel_main


// -----------------------------------------------------------------------------
// Minimal boot MMU setup
// -----------------------------------------------------------------------------
.align 4
boot_enable_mmu:
    // Zero page tables (6 pages).
    adrp    x0, boot_ttbr0_l0
    add     x0, x0, :lo12:boot_ttbr0_l0
    mov     x1, #0
    mov     x2, #(4096 * 6 / 16)      // stp x?,x? zeros 16 bytes per iter
1:
    stp     x1, x1, [x0], #16
    subs    x2, x2, #1
    b.ne    1b

    // Build TTBR0 tables: L0[0] -> L1, L1[0] -> L2
    adrp    x10, boot_ttbr0_l0
    add     x10, x10, :lo12:boot_ttbr0_l0
    adrp    x11, boot_ttbr0_l1
    add     x11, x11, :lo12:boot_ttbr0_l1
    adrp    x12, boot_ttbr0_l2
    add     x12, x12, :lo12:boot_ttbr0_l2

    orr     x13, x11, #0x3            // table descriptor
    str     x13, [x10, #0]            // L0[0]
    orr     x13, x12, #0x3
    str     x13, [x11, #0]            // L1[0]

    // Build TTBR1 tables: L0[511] -> L1, L1[0] -> L2
    adrp    x14, boot_ttbr1_l0
    add     x14, x14, :lo12:boot_ttbr1_l0
    adrp    x15, boot_ttbr1_l1
    add     x15, x15, :lo12:boot_ttbr1_l1
    adrp    x16, boot_ttbr1_l2
    add     x16, x16, :lo12:boot_ttbr1_l2

    orr     x13, x15, #0x3
    str     x13, [x14, #(511 * 8)]    // L0[511]
    orr     x13, x16, #0x3
    str     x13, [x15, #0]            // L1[0]

    // Common flags for 2MB block entries.
    // Bits:
    //  - [1:0] 01 = block, bit0 set by .valid, bit1 cleared
    //  - [4:2] AttrIndx (0 = normal, 1 = device)
    //  - [9:8] SH (inner = 0b11, non-shareable = 0b00)
    //  - [10]  AF
    mov     x17, #(1 << 10)           // AF
    orr     x17, x17, #(3 << 8)       // SH = inner-shareable
    // AttrIndx = 0 (normal) already
    orr     x17, x17, #0x1            // valid + block

    // Device flags: AttrIndx = 1, SH = non-shareable.
    mov     x18, #(1 << 10)           // AF
    orr     x18, x18, #(1 << 2)       // AttrIndx = 1
    orr     x18, x18, #0x1            // valid + block

    // Fill L2 with 2MB blocks for the first 1GB (512 entries).
    mov     x19, #0                   // index
2:
    // base PA = index * 2MB
    lsl     x20, x19, #21
    // default: normal memory
    orr     x21, x20, x17

    // Override a couple of known device blocks (QEMU virt).
    // GIC at 0x0800_0000 (index 0x40), UART at 0x0900_0000 (index 0x48).
    cmp     x19, #0x40
    b.eq    3f
    cmp     x19, #0x48
    b.eq    3f
    b       4f
3:
    orr     x21, x20, x18
4:
    str     x21, [x12, x19, lsl #3]   // TTBR0 L2
    str     x21, [x16, x19, lsl #3]   // TTBR1 L2
    add     x19, x19, #1
    cmp     x19, #512
    b.ne    2b

    // Program MAIR / TCR and enable MMU (same values as AArch64MMUHandlers.S).
    ldr     x2, =0x00000000000004FF
    msr     mair_el1, x2

    ldr     x2, =((16 << 0)  | (16 << 16) | \
                  (3 << 12)  | (3 << 28)  | \
                  (1 << 8)   | (1 << 10)  | \
                  (1 << 24)  | (1 << 26)  | \
                  (0 << 14)  | (2 << 30))
    msr     tcr_el1, x2

    // TTBR0/TTBR1 expect physical addresses.
    adrp    x0, boot_ttbr0_l0
    add     x0, x0, :lo12:boot_ttbr0_l0
    adrp    x1, boot_ttbr1_l0
    add     x1, x1, :lo12:boot_ttbr1_l0
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x1

    tlbi    vmalle1
    ic      iallu
    dsb     sy
    isb

    mrs     x2, sctlr_el1
    ldr     x3, =0x1005
    orr     x2, x2, x3
    msr     sctlr_el1, x2
    isb
    ret


.section .bss, "aw", %nobits
.balign 4096
boot_ttbr0_l0: .skip 4096
.balign 4096
boot_ttbr0_l1: .skip 4096
.balign 4096
boot_ttbr0_l2: .skip 4096
.balign 4096
boot_ttbr1_l0: .skip 4096
.balign 4096
boot_ttbr1_l1: .skip 4096
.balign 4096
boot_ttbr1_l2: .skip 4096
