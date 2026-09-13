//  ContextSwitch.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

// Global label, call swift func
.global jump_to_user_mode

// Procedure Params:
//     x0 = TrapFrame Pointer
//     x1 = User RootTable Address
//
// The EL1 exception stack is the single dedicated kernel stack reserved by
// the linker (.stack section, symbol stack_top). It is intentionally not a
// per-process stack: this kernel is non-preemptive at EL1 (IRQs masked) and
// every syscall runs to completion, unwinding the stack before eret, so a
// single shared stack is sufficient and is kept anchored at stack_top.
jump_to_user_mode:
    
    adr     x3, safe_high_half
    ldr     x4, =0xFFFF800000000000
    add     x3, x3, x4
    br      x3

safe_high_half:
    msr     daifset, #3

    // Untagged TTBR0 write: bits [63, 48] stay zero, so the first process runs
    // under ASID 0 until the scheduler switches away from it and back through
    // switch_user_address_space, which installs its real ASID. Its non-global
    // entries are cached as ASID 0 and are simply re-walked at that point.
    msr     ttbr0_el1, x1
    tlbi    vmalle1is
    dsb     ish
    isb

    ldr     x2, =stack_top
    ldr     x3, =0xFFFF800000000000
    add     sp, x2, x3

    // This is the first entry for a new process and the resume path for every
    // later one. Restore the complete eager FP/SIMD image only after leaving
    // Swift, so no compiler-generated vector instruction can overwrite it.
    ldp     q0, q1,    [x0, #288]
    ldp     q2, q3,    [x0, #320]
    ldp     q4, q5,    [x0, #352]
    ldp     q6, q7,    [x0, #384]
    ldp     q8, q9,    [x0, #416]
    ldp     q10, q11,  [x0, #448]
    ldp     q12, q13,  [x0, #480]
    ldp     q14, q15,  [x0, #512]
    ldp     q16, q17,  [x0, #544]
    ldp     q18, q19,  [x0, #576]
    ldp     q20, q21,  [x0, #608]
    ldp     q22, q23,  [x0, #640]
    ldp     q24, q25,  [x0, #672]
    ldp     q26, q27,  [x0, #704]
    ldp     q28, q29,  [x0, #736]
    ldp     q30, q31,  [x0, #768]

    ldr     x2,        [x0, #800]
    ldr     x3,        [x0, #808]
    msr     fpcr, x2
    msr     fpsr, x3

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
