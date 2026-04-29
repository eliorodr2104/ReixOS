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
.global is_mmu_enabled
.global jump_to_high_half
.global set_vbar


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


.global enable_mmu
enable_mmu:
    // x0 = Puntatore TTBR0 (Identity / User)
    // x1 = Puntatore TTBR1 (Kernel High Half)

    // 1. Carica le tabelle base
    msr     ttbr0_el1, x0
    msr     ttbr1_el1, x1

    // 2. MAIR_EL1 (Memoria Normale vs Periferiche)
    // 0xFF in Index 0 = Normal Memory (Cacheable, Write-Back)
    ldr     x2, =0x00000000000000FF
    msr     mair_el1, x2

    // 3. TCR_EL1 (Page Table Walker DEVE leggere la Cache!)
    // Questo è il numero magico per 48-bit VA e Cache Coherency
    ldr     x2, =0x32B5503510
    msr     tcr_el1, x2

    // 4. Sblocca FP/SIMD per Swift (altrimenti Swift crasherà)
    mrs     x2, cpacr_el1
    orr     x2, x2, #(3 << 20)
    msr     cpacr_el1, x2

    isb     // Sincronizza i registri prima di accendere il motore

    // 5. IL GRANDE INTERRUTTORE (SCTLR_EL1)
    mrs     x2, sctlr_el1
    orr     x2, x2, #1          // Bit 0: Attiva la MMU
    orr     x2, x2, #(1 << 2)   // Bit 2: Attiva la DATA CACHE (Critico!)
    orr     x2, x2, #(1 << 12)  // Bit 12: Attiva la INSTRUCTION CACHE
    msr     sctlr_el1, x2

    isb
    ret

is_mmu_enabled:
    mrs     x0, sctlr_el1
    and     x0, x0, #1
    ret


jump_to_high_half:
    mov     x1, sp
    add     x1, x1, x0
    mov     sp, x1

    add     x30, x30, x0

    adr     x1, .L_trampoline_target
    add     x1, x1, x0
    
    br      x1

.L_trampoline_target:
    ret

set_vbar:
    msr vbar_el1, x0
    ret
