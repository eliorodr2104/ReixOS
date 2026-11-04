// Isolated kernel-side FP/SIMD probe, linked only with
// REIX_FPSIMD_DIAGNOSTIC=1. ContextSaving.S owns the matching intentional
// nested-entry clobber. This file never enters an ordinary ReixOS image.

.macro set_probe_q register
    ins     v\register\().d[0], x2
    ins     v\register\().d[1], x3
    add     x2, x2, #1
    add     x3, x3, #1
.endm

.macro check_probe_q register
    umov    x4, v\register\().d[0]
    cmp     x4, x2
    b.ne    .L_q_mismatch
    umov    x4, v\register\().d[1]
    cmp     x4, x3
    b.ne    .L_q_mismatch
    add     x2, x2, #1
    add     x3, x3, #1
.endm

.section .bss
.align 3
.global fpsimd_diagnostic_nested_status
fpsimd_diagnostic_nested_status:
    .quad 0

.global fpsimd_diagnostic_environment_failure
fpsimd_diagnostic_environment_failure:
    .quad 0

.section .text
.align 2

.global fpsimd_diagnostic_environment_failed
.type fpsimd_diagnostic_environment_failed, %function
fpsimd_diagnostic_environment_failed:
    adrp    x1, fpsimd_diagnostic_environment_failure
    add     x1, x1, :lo12:fpsimd_diagnostic_environment_failure
    ldr     x0, [x1]
    ret
.size fpsimd_diagnostic_environment_failed, .-fpsimd_diagnostic_environment_failed

.global fpsimd_run_nested_probe
.type fpsimd_run_nested_probe, %function
fpsimd_run_nested_probe:
    // AAPCS64 preserves only the low 64 bits of v8-v15. Keep those lanes and
    // the caller's FP environment while the complete architectural image is
    // filled with sentinels and checked across the asynchronous exception.
    sub     sp, sp, #96
    stp     d8, d9,   [sp, #0]
    stp     d10, d11, [sp, #16]
    stp     d12, d13, [sp, #32]
    stp     d14, d15, [sp, #48]
    mrs     x4, fpcr
    mrs     x5, fpsr
    stp     x4, x5,   [sp, #64]
    mrs     x6, daif
    str     x6,       [sp, #80]

    adrp    x7, fpsimd_diagnostic_nested_status
    add     x7, x7, :lo12:fpsimd_diagnostic_nested_status
    str     xzr, [x7]
    adrp    x7, fpsimd_diagnostic_environment_failure
    add     x7, x7, :lo12:fpsimd_diagnostic_environment_failure
    str     xzr, [x7]

    movz    x2, #0x6100, lsl #48
    movz    x3, #0xB200, lsl #48
    set_probe_q 0
    set_probe_q 1
    set_probe_q 2
    set_probe_q 3
    set_probe_q 4
    set_probe_q 5
    set_probe_q 6
    set_probe_q 7
    set_probe_q 8
    set_probe_q 9
    set_probe_q 10
    set_probe_q 11
    set_probe_q 12
    set_probe_q 13
    set_probe_q 14
    set_probe_q 15
    set_probe_q 16
    set_probe_q 17
    set_probe_q 18
    set_probe_q 19
    set_probe_q 20
    set_probe_q 21
    set_probe_q 22
    set_probe_q 23
    set_probe_q 24
    set_probe_q 25
    set_probe_q 26
    set_probe_q 27
    set_probe_q 28
    set_probe_q 29
    set_probe_q 30
    set_probe_q 31

    mov     x4, #0x03000000
    msr     fpcr, x4
    mov     x5, #0x1F
    movk    x5, #0x0800, lsl #16
    msr     fpsr, x5

    // Timer and GIC are live before Kernel.run calls this function. Wait until
    // ContextSaving.S marks an EL1 entry, tolerating an architecturally legal
    // spurious WFI wake without accepting it as evidence.
    msr     daifclr, #2
.L_wait_for_nested_irq:
    wfi
    adrp    x7, fpsimd_diagnostic_nested_status
    add     x7, x7, :lo12:fpsimd_diagnostic_nested_status
    ldr     x7, [x7]
    cbz     x7, .L_wait_for_nested_irq
    msr     daifset, #2

    cmp     x7, #1
    b.ne    .L_nested_status_failure

    movz    x2, #0x6100, lsl #48
    movz    x3, #0xB200, lsl #48
    check_probe_q 0
    check_probe_q 1
    check_probe_q 2
    check_probe_q 3
    check_probe_q 4
    check_probe_q 5
    check_probe_q 6
    check_probe_q 7
    check_probe_q 8
    check_probe_q 9
    check_probe_q 10
    check_probe_q 11
    check_probe_q 12
    check_probe_q 13
    check_probe_q 14
    check_probe_q 15
    check_probe_q 16
    check_probe_q 17
    check_probe_q 18
    check_probe_q 19
    check_probe_q 20
    check_probe_q 21
    check_probe_q 22
    check_probe_q 23
    check_probe_q 24
    check_probe_q 25
    check_probe_q 26
    check_probe_q 27
    check_probe_q 28
    check_probe_q 29
    check_probe_q 30
    check_probe_q 31

    mrs     x4, fpcr
    mov     x5, #0x03000000
    cmp     x4, x5
    b.ne    .L_fpcr_mismatch

    mrs     x4, fpsr
    mov     x5, #0x1F
    movk    x5, #0x0800, lsl #16
    cmp     x4, x5
    b.ne    .L_fpsr_mismatch

    adrp    x7, fpsimd_diagnostic_environment_failure
    add     x7, x7, :lo12:fpsimd_diagnostic_environment_failure
    ldr     x7, [x7]
    cbnz    x7, .L_environment_failure

    mov     x0, #0
    b       .L_probe_done

.L_nested_status_failure:
    mov     x0, #1
    b       .L_probe_done
.L_q_mismatch:
    mov     x0, #2
    b       .L_probe_done
.L_fpcr_mismatch:
    mov     x0, #3
    b       .L_probe_done
.L_fpsr_mismatch:
    mov     x0, #4
    b       .L_probe_done
.L_environment_failure:
    mov     x0, #5

.L_probe_done:
    ldp     x4, x5,   [sp, #64]
    msr     fpcr, x4
    msr     fpsr, x5
    ldp     d8, d9,   [sp, #0]
    ldp     d10, d11, [sp, #16]
    ldp     d12, d13, [sp, #32]
    ldp     d14, d15, [sp, #48]
    ldr     x6,       [sp, #80]
    msr     daif, x6
    add     sp, sp, #96
    ret
.size fpsimd_run_nested_probe, .-fpsimd_run_nested_probe
