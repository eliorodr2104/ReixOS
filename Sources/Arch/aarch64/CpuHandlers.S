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
    // 1. Configurazione MAIR_EL1 (Immutata, 0x4FF è corretta)
    ldr     x2, =0x00000000000004FF
    msr     mair_el1, x2

    // 2. Configurazione TCR_EL1 (Immutata, 48-bit VA, 4KB granule)
    ldr     x2, =((16 << 0)  | (16 << 16) | \
                  (3 << 12)  | (3 << 28)  | \
                  (1 << 8)   | (1 << 10)  | \
                  (1 << 24)  | (1 << 26)  | \
                  (0 << 14)  | (2 << 30))
    msr     tcr_el1, x2

    // 3. Caricamento dei registri radice (LA MODIFICA)
    msr     ttbr0_el1, x0    // Tabella Identity (indirizzi bassi 0x00...)
    msr     ttbr1_el1, x1    // Tabella Kernel   (indirizzi alti  0xFF...)

    // 4. Sincronizzazione e Invalida TLB/Cache
    tlbi    vmalle1
    ic      iallu
    dsb     sy
    isb

    // 5. Attivazione MMU tramite SCTLR_EL1
    mrs     x2, sctlr_el1
    ldr     x3, =0x1005      // M=1 (MMU), A=1 (Alignment), C=1 (Cache), I=1 (Instr Cache)
    orr     x2, x2, x3
    msr     sctlr_el1, x2
    
    // Barriera finale per garantire che la MMU sia attiva prima del prossimo salto
    isb
    ret

is_mmu_enabled:
    mrs     x0, sctlr_el1
    and     x0, x0, #1
    ret
