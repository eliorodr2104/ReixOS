//  ContextSaving.S
//  ReixOS

.macro ventry label
    .align 7
    b \label
.endm

.equ TRAP_FRAME_SIZE, 816
.equ FP_STATE_OFFSET, 800

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
    sub     sp, sp, #TRAP_FRAME_SIZE
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
    sub     sp, sp, #TRAP_FRAME_SIZE
.endm

#ifdef REIX_FPSIMD_DIAGNOSTIC
// Deliberately destroys every Q register and both FP control registers on an
// EL1 entry. The isolated guest probe enters WFI with sentinels in all of them;
// surviving this block proves the nested exception returned from the frame,
// rather than from the AAPCS64 subset a normal function call would preserve.
.macro diagnostic_clobber_q register
    ins     v\register\().d[0], x2
    ins     v\register\().d[1], x3
    add     x2, x2, #1
    add     x3, x3, #1
.endm

.macro diagnostic_clobber_nested_fpsimd
    // This check runs on EL0 and EL1 entries at the last instruction boundary
    // before Swift. A diagnostic handler turns a recorded failure into a panic.
    mrs     x1, fpcr
    mrs     x2, fpsr
    orr     x1, x1, x2
    cbz     x1, 7f
    adrp    x0, fpsimd_diagnostic_environment_failure
    add     x0, x0, :lo12:fpsimd_diagnostic_environment_failure
    mov     x1, #1
    str     x1, [x0]
7:
    ldr     x0, [sp, #256]
    and     x0, x0, #0xF
    cmp     x0, #5
    b.ne    9f

    adrp    x0, fpsimd_diagnostic_nested_status
    add     x0, x0, :lo12:fpsimd_diagnostic_nested_status
    mov     x1, #1
    str     x1, [x0]

    movz    x2, #0x1100, lsl #48
    movz    x3, #0xA500, lsl #48
    diagnostic_clobber_q 0
    diagnostic_clobber_q 1
    diagnostic_clobber_q 2
    diagnostic_clobber_q 3
    diagnostic_clobber_q 4
    diagnostic_clobber_q 5
    diagnostic_clobber_q 6
    diagnostic_clobber_q 7
    diagnostic_clobber_q 8
    diagnostic_clobber_q 9
    diagnostic_clobber_q 10
    diagnostic_clobber_q 11
    diagnostic_clobber_q 12
    diagnostic_clobber_q 13
    diagnostic_clobber_q 14
    diagnostic_clobber_q 15
    diagnostic_clobber_q 16
    diagnostic_clobber_q 17
    diagnostic_clobber_q 18
    diagnostic_clobber_q 19
    diagnostic_clobber_q 20
    diagnostic_clobber_q 21
    diagnostic_clobber_q 22
    diagnostic_clobber_q 23
    diagnostic_clobber_q 24
    diagnostic_clobber_q 25
    diagnostic_clobber_q 26
    diagnostic_clobber_q 27
    diagnostic_clobber_q 28
    diagnostic_clobber_q 29
    diagnostic_clobber_q 30
    diagnostic_clobber_q 31

    mov     x2, #0x03000000
    msr     fpcr, x2
    mov     x3, #0x1F
    movk    x3, #0x0800, lsl #16
    msr     fpsr, x3

    // Leave the environment promised to the Swift handler intact after the
    // deliberate damage. Q registers have no analogous control state.
    msr     fpcr, xzr
    msr     fpsr, xzr
9:
.endm
#endif

// Completes the trap frame the entry stub started, and leaves x0 pointing at it
// with x1 carrying whatever the stub put in x0.
//
// x0 and x1 are already stored by the stub, because x1 is reused to pass the
// exception type to Swift.
.macro save_trap_frame
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

    // Save the complete architectural FP/SIMD state before the first Swift
    // instruction can use it. The offsets are the appended portion of
    // AArch64TrapFrame; the earlier GPR/system layout remains unchanged.
    stp     q0, q1,    [sp, #288]
    stp     q2, q3,    [sp, #320]
    stp     q4, q5,    [sp, #352]
    stp     q6, q7,    [sp, #384]
    stp     q8, q9,    [sp, #416]
    stp     q10, q11,  [sp, #448]
    stp     q12, q13,  [sp, #480]
    stp     q14, q15,  [sp, #512]
    stp     q16, q17,  [sp, #544]
    stp     q18, q19,  [sp, #576]
    stp     q20, q21,  [sp, #608]
    stp     q22, q23,  [sp, #640]
    stp     q24, q25,  [sp, #672]
    stp     q26, q27,  [sp, #704]
    stp     q28, q29,  [sp, #736]
    stp     q30, q31,  [sp, #768]

    mrs     x0, fpcr
    mrs     x1, fpsr
    str     x0,         [sp, #FP_STATE_OFFSET]
    str     x1,         [sp, #(FP_STATE_OFFSET + 8)]

    // Every Swift handler starts from one deterministic FP environment. A
    // nested EL1 exception preserves the interrupted kernel FP/SIMD state in
    // its own frame, clears FPCR/FPSR for its handler, and restores the saved
    // environment before resuming the interrupted kernel code.
    msr     fpcr, xzr
    msr     fpsr, xzr

#ifdef REIX_FPSIMD_DIAGNOSTIC
    diagnostic_clobber_nested_fpsimd
#endif

    mov     x1,       x5

    mov     x0, sp
.endm

// The prologue shared by every vector this kernel installs no handler for.
// \id names the slot, and is the only thing Swift can tell them apart by.
//
// SP is re-anchored before the first store rather than checked, because these
// slots can fire in any context: the SP0 group runs on a stack that is never
// set up, and an SError can arrive while SP is already off the kernel stack. The
// frame is a real one, so the panic report carries ESR, ELR, FAR and the
// registers instead of an address and a guess.
.macro invalid_entry id
    switch_to_exception_stack
    stp     x0, x1,   [sp, #0]
    mov     x0, #\id
    b       report_invalid_vector
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
    sub     sp, sp, #TRAP_FRAME_SIZE
    stp     x0, x1,   [sp, #0]
    mov     x0, #1       // 1 = Sync
    b       save_context_after_x0_x1

irq_handler_el0:
    sub     sp, sp, #TRAP_FRAME_SIZE
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
    b       report_kernel_stack_overflow

irq_handler_el1:
    check_kernel_stack .L_irq_el1_overflow
    stp     x0, x1,   [sp, #0]
    mov     x0, #0       // 0 = IRQ
    b       save_context_after_x0_x1

.L_irq_el1_overflow:
    switch_to_exception_stack
    stp     x0, x1,   [sp, #0]
    b       report_kernel_stack_overflow


// Returning from an EL1 overflow would strand SP_EL1 on the exception stack:
// that register is not part of the architectural exception state restored by
// eret. Save the complete interrupted context for the report and fail closed.
report_kernel_stack_overflow:
    save_trap_frame
    bl      swift_kernel_stack_overflow

.L_kernel_stack_overflow_halt:
    wfi
    b       .L_kernel_stack_overflow_halt


// The slot ids are the contract with `swift_invalid_vector`, and are spelled
// out again in InvalidVectorHandler.swift. Nothing else reads them.
sync_invalid:
    invalid_entry 0

irq_invalid:
    invalid_entry 1

fiq_invalid:
    invalid_entry 2

serror_invalid:
    invalid_entry 3

handler_invalid:
    invalid_entry 4


// Reached with the slot id in x0 and the frame already reserved on the
// exception stack. save_trap_frame turns that into the (frame, id) pair Swift
// is called with.
//
// `swift_invalid_vector` panics and does not return. The halt below is only for
// the case where the panic path itself fails to reach its own halt: there is no
// handler behind these vectors, so there is nothing to eret to.
report_invalid_vector:
    save_trap_frame
    bl      swift_invalid_vector

.L_invalid_halt:
    wfi
    b       .L_invalid_halt


save_context_after_x0_x1:
    save_trap_frame
    bl      swift_exception_handler

    // RESTORE CONTEXT
    ldp     q0, q1,    [sp, #288]
    ldp     q2, q3,    [sp, #320]
    ldp     q4, q5,    [sp, #352]
    ldp     q6, q7,    [sp, #384]
    ldp     q8, q9,    [sp, #416]
    ldp     q10, q11,  [sp, #448]
    ldp     q12, q13,  [sp, #480]
    ldp     q14, q15,  [sp, #512]
    ldp     q16, q17,  [sp, #544]
    ldp     q18, q19,  [sp, #576]
    ldp     q20, q21,  [sp, #608]
    ldp     q22, q23,  [sp, #640]
    ldp     q24, q25,  [sp, #672]
    ldp     q26, q27,  [sp, #704]
    ldp     q28, q29,  [sp, #736]
    ldp     q30, q31,  [sp, #768]

    ldr     x2,         [sp, #FP_STATE_OFFSET]
    ldr     x3,         [sp, #(FP_STATE_OFFSET + 8)]
    msr     fpcr, x2
    msr     fpsr, x3

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

    add     sp, sp, #TRAP_FRAME_SIZE
    eret
