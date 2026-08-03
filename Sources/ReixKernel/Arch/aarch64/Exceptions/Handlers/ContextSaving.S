//  ContextSaving.S
//  ReixOS

.macro ventry label
    .align 7
    b \label
.endm

// Reserves the trap frame and branches to \overflow if it does not fit on the
// kernel stack, for exceptions taken at EL1.
//
// It has to run before the first store. Once SP has walked into the guard page
// below __stack_bottom, the prologue's own stp is the next access into it, so
// the abort re-enters here and the kernel spins at a fixed PC with nothing
// reported. Below the guard page lies .bss.
//
// x0 is parked in CONTEXTIDR_EL1, an EL1 software field this kernel never reads
// and does not carry in any context it saves. No general register may simply be
// spilled instead: the panic report prints all of them. Nothing can nest inside
// the window and observe the parked value, since it takes no memory access and
// the exception entry has already masked DAIF.
//
// The comparison is 32 bits wide because SP and the symbol can sit in different
// aliases of the same page: VBAR_EL1 is never moved off the identity mapping,
// so the vectors run at a low PC and adrp yields the low alias, while SP is
// high-half from the first entry into user mode onward. The two aliases differ
// only above bit 32.
//
// Only the low side is tested, because a runaway call chain is what walks SP
// off the stack. Bounding it above as well would need the stack size as an
// assembly-time constant, which means restating linker.ld here and being
// silently wrong the day the two disagree.
.macro check_kernel_stack overflow
    msr     contextidr_el1, x0
    sub     sp, sp, #288
    adrp    x0, __stack_bottom
    add     x0, x0, :lo12:__stack_bottom
    cmp     wsp, w0
    mrs     x0, contextidr_el1
    b.lo    \overflow
.endm

// Re-anchors SP at the top of the exception stack and reserves the trap frame
// there. Reached only from check_kernel_stack, so the kernel stack is already
// unusable and nothing on it is worth preserving.
//
// adrp resolves in whichever alias the vectors are running in, and both are
// mapped, so this is correct before and after the switch to the high half.
.macro switch_to_exception_stack
    msr     contextidr_el1, x0
    adrp    x0, __exception_stack_top
    add     x0, x0, :lo12:__exception_stack_top
    mov     sp, x0
    mrs     x0, contextidr_el1
    sub     sp, sp, #288
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

    // Group 3: Lower EL using AArch64 (User Mode 64-bit)
    ventry sync_handler_el0    // Syscall (svc), Page Faults user, ecc.
    ventry irq_handler_el0     // Timer hardware & IO!
    ventry fiq_invalid
    ventry serror_invalid

    // Group 4: Lower EL using AArch32 (Not supported)
    ventry handler_invalid
    ventry handler_invalid
    ventry handler_invalid
    ventry handler_invalid

// --- Handler Implementations ---

sync_handler_el0:
    sub     sp, sp, #288
    stp     x0, x1,   [sp, #0]
    mov     x0, #1       // 1 = Sync
    b       save_context_after_x0_x1

irq_handler_el0:
    sub     sp, sp, #288
    stp     x0, x1,   [sp, #0]
    mov     x0, #0       // 0 = IRQ
    b       save_context_after_x0_x1

// Only the EL1 entries check the stack. An exception from EL0 finds the kernel
// stack empty by construction, because EL0 was running and jump_to_user_mode
// left SP at stack_top, so on that path the check would spend its instructions
// proving something already known.
sync_handler_el1:
    check_kernel_stack .L_sync_el1_overflow
    stp     x0, x1,   [sp, #0]
    mov     x0, #1       // 1 = Sync
    b       save_context_after_x0_x1

.L_sync_el1_overflow:
    switch_to_exception_stack
    stp     x0, x1,   [sp, #0]
    mov     x0, #1
    b       save_context_after_x0_x1

irq_handler_el1:
    check_kernel_stack .L_irq_el1_overflow
    stp     x0, x1,   [sp, #0]
    mov     x0, #0       // 0 = IRQ
    b       save_context_after_x0_x1

.L_irq_el1_overflow:
    switch_to_exception_stack
    stp     x0, x1,   [sp, #0]
    mov     x0, #0
    b       save_context_after_x0_x1


sync_invalid:
irq_invalid:
fiq_invalid:
serror_invalid:
handler_invalid:
    b . // TODO: Manage this error


save_context_after_x0_x1:
    // Save general registers. x0/x1 are already saved by the entry stub,
    // because x1 is reused to pass the exception type to Swift.
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

    mov     x5, x0

    // Save critical system register
    mrs     x0, elr_el1
    mrs     x1, spsr_el1
    mrs     x2, esr_el1
    mrs     x3, far_el1
    mrs     x4, sp_el0
    
    
    stp     x0, x1,   [sp, #248]
    stp     x2, x3,   [sp, #264]
    str     x4,       [sp, #280]
    mov     x1,       x5
    
    mov     x0, sp
    bl      swift_exception_handler

    // RESTORE CONTEXT
    ldp     x0, x1,   [sp, #248]
    ldp     x2, x3,   [sp, #264]
    ldr     x4,       [sp, #280]
    
    msr     elr_el1,  x0
    msr     spsr_el1, x1
    msr     sp_el0,   x4
    
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

    add     sp, sp, #288
    eret
