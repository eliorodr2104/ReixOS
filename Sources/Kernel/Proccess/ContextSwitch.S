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

    // --- Trampolino verso la High Memory (TTBR1) ---
    adr     x3, safe_high_half
    ldr     x4, =0xFFFF800000000000
    add     x3, x3, x4
    br      x3

safe_high_half:
    // 1. Applichiamo la memoria utente
    msr     ttbr0_el1, x1
    tlbi    vmalle1is
    dsb     ish
    isb

    // <-- LA CORREZIONE MAGICA -->
    // 2. Impostiamo SUBITO lo stack del Kernel per le future interruzioni.
    // Ora SP_EL1 è al sicuro e non lo toccheremo più.
    mov     sp, x2

    // 3. RESTORE DEI REGISTRI DI SISTEMA 
    // Attenzione: usiamo [x0] come base, non più [sp]!
    ldp     x3, x4,   [x0, #248]    // Leggiamo ELR (in x3) e SPSR (in x4)
    msr     elr_el1,  x3
    msr     spsr_el1, x4

    ldr     x5,       [x0, #280]    // Leggiamo SP_EL0 (in x5)
    msr     sp_el0,   x5

    // 4. RESTORE DEI REGISTRI GENERALI
    // Ripristiniamo tutto da x2 a x30. Lasciamo indietro x0 e x1.
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

    // 5. IL TOCCO FINALE
    // Adesso che abbiamo letto tutto il TrapFrame, possiamo sovrascrivere x0.
    // Leggiamo gli ultimi due registri mancanti!
    ldp     x0, x1,   [x0, #0]

    // 6. SALTO NEL VUOTO
    eret
