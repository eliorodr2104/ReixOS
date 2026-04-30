//  ContextSwitch.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

.global jump_to_user_mode
jump_to_user_mode:
    // x0 = Puntatore al TrapFrame
    // x1 = Indirizzo RootTable Utente
    // x2 = Indirizzo Cima del Kernel Stack
    
    adr     x3, safe_high_half
    ldr     x4, =0xFFFF800000000000
    add     x3, x3, x4
    br      x3

safe_high_half:
    msr     daifset, #3
    msr     ttbr0_el1, x1
    tlbi    vmalle1is
    dsb     ish
    isb

    mov     sp, x2

    ldp     x3, x4,   [x0, #248]
    msr     elr_el1,  x3
    msr     spsr_el1, x4

    ldr     x5,       [x0, #280]
    msr     sp_el0,   x5

    ldp     x2, x3,   [x0, #16]
    ldp     x4, x5,   [x0, #32]
    ldp     x6, x7,   [x0, #48]
    ldp     x8, x9,   [x0, #64]
    ldp     x10, x11, [x0, #80]
    ldp     x12, x13, [x0, #96]
    ldp     x14, x15, [x0, #112]
    ldp     x16, x17, [x0, #128]
    ldp     x18, x19, [x0, #144]
    ldp     x20, x21, [x0, #160]
    ldp     x22, x23, [x0, #176]
    ldp     x24, x25, [x0, #192]
    ldp     x26, x27, [x0, #208]
    ldp     x28, x29, [x0, #224]
    ldr     x30,      [x0, #240]

    ldp     x0, x1,   [x0, #0]

    eret
