;
//  MMUHandlers.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


.global enable_mmu
.global is_mmu_enabled
.global flush_tlb

enable_mmu:
    ldr     x2, =0x00000000000004FF
    msr     mair_el1, x2

    ldr     x2, =((16 << 0)  | (16 << 16) | \
                  (3 << 12)  | (3 << 28)  | \
                  (1 << 8)   | (1 << 10)  | \
                  (1 << 24)  | (1 << 26)  | \
                  (0 << 14)  | (2 << 30))
    msr     tcr_el1, x2

    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x1

    tlbi    vmalle1
    ic      iallu
    dsb     sy
    isb

    mrs     x2, sctlr_el1
    ldr     x3, =0x1005      // M=1 (MMU), A=1 (Alignment), C=1 (Cache), I=1 (Instr Cache)
    orr     x2, x2, x3
    msr     sctlr_el1, x2
    
    isb
    ret

is_mmu_enabled:
    mrs     x0, sctlr_el1
    and     x0, x0, #1
    ret

flush_tlb:
    dsb ishst     
    tlbi vmalle1is
    dsb ish
    isb
    ret
