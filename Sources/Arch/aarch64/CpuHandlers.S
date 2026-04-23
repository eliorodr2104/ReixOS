;
//  CpuHandlers.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

.section .text
.global disable_interrupts
.global wait_for_interrupt
.global enable_interrupts
.global nop
.global wait_for_exception
.global trigger_trap
.global flush_tlb
.global enable_mmu

disable_interrupts:
    msr daifset, #3
    ret

enable_interrupts:
    msr daifclr, #3
    ret

wait_for_interrupt:
    wfi
    ret

nop:
    nop
    ret
    
wait_for_exception:
    wfe
    b wait_for_exception

trigger_trap:
    brk #0

flush_tlb:
    dsb ishst     
    tlbi vmalle1is
    dsb ish
    isb
    ret


enable_mmu:
    ldr     x1, =0x00000000000004FF
    msr     mair_el1, x1


    ldr     x1, =((16 << 0) | (16 << 16) | (0 << 14) | (2 << 30))
    msr     tcr_el1, x1

    msr     ttbr1_el1, x0
    msr     ttbr0_el1, x0

    dsb     sy
    isb

    mrs     x1, sctlr_el1
    orr     x1, x1, #0x1        // Bit 0: M (MMU Enable)
    //orr     x1, x1, #0x4        // Bit 2: C (Data Cache)
    //orr     x1, x1, #0x1000     // Bit 12: I (Instruction Cache)
    msr     sctlr_el1, x1

    isb
    ret
