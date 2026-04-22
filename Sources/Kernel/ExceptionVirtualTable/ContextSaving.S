//  ContextSaving.S
//  ReixOS - Fixed version

.macro ventry label
    .align 7
    b \label
.endm

.section .vectors, "ax"
.align 11

.global _evt_start
_evt_start:
    // Group 1: Current EL with SP0
    ventry sync_invalid
    ventry irq_invalid
    ventry fiq_invalid
    ventry serror_invalid

    // Group 2: Current EL with SPx (Kernel context)
    ventry sync_handler_el1
    ventry irq_handler_el1
    ventry fiq_invalid
    ventry serror_invalid

    // Group 3 & 4 (User mode) - Per ora invalidi
    .rept 8
    ventry handler_invalid
    .endr

// --- Handler Implementations ---

sync_handler_el1:
    b save_context

irq_handler_el1:
    b save_context

sync_invalid:
irq_invalid:
fiq_invalid:
serror_invalid:
handler_invalid:
    b . // TODO: Manage this error

save_context:
    // 256 Byte for all data
    sub     sp, sp, #272

    // Save general registers
    stp     x0, x1,   [sp, #0]
    stp     x2, x3,   [sp, #16]
    stp     x4, x5,   [sp, #32]
    stp     x6, x7,   [sp, #48]
    stp     x8, x9,   [sp, #64]
    stp     x10, x11, [sp, #80]
    stp     x12, x13, [sp, #96]
    stp     x14, x15, [sp, #112]
    stp     x16, x17, [sp, #128]
    stp     x18, x19, [sp, #144]
    stp     x20, x21, [sp, #160]
    stp     x22, x23, [sp, #176]
    stp     x24, x25, [sp, #192]
    stp     x26, x27, [sp, #208]
    stp     x28, x29, [sp, #224]
    str     x30,      [sp, #240]

    // Save critical system register
    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    mrs     x2, esr_el1
    
    stp     x0, x1,   [sp, #248]
    str     x2,       [sp, #264]
    
    mov     x0, sp
    bl      swift_exception_handler

    // RESTORE CONTEXT
    ldr     x2,       [sp, #264]
    ldp     x0, x1,   [sp, #248]
    
    msr     elr_el1, x0
    msr     spsr_el1, x1
    
    ldp     x0, x1,   [sp, #0]
    ldp     x2, x3,   [sp, #16]
    ldp     x4, x5,   [sp, #32]
    ldp     x6, x7,   [sp, #48]
    ldp     x8, x9,   [sp, #64]
    ldp     x10, x11, [sp, #80]
    ldp     x12, x13, [sp, #96]
    ldp     x14, x15, [sp, #112]
    ldp     x16, x17, [sp, #128]
    ldp     x18, x19, [sp, #144]
    ldp     x20, x21, [sp, #160]
    ldp     x22, x23, [sp, #176]
    ldp     x24, x25, [sp, #192]
    ldp     x26, x27, [sp, #208]
    ldp     x28, x29, [sp, #224]
    ldr     x30,      [sp, #240]

    add     sp, sp, #272
    eret
