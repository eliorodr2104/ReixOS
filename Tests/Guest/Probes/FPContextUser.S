// Independent EL0 oracle. Replaces app archives only in diagnostic snapshots.
// No Swift or C runs between the first instruction and the initial-state capture.
// ROOT_PROBE selects Init vs StorageCheck; PERF_ONLY makes a single-process timer benchmark.
.text
.align 4
.global _start
_start:
    adrp x25, expected
    add x25, x25, :lo12:expected
    adrp x26, observed
    add x26, x26, :lo12:observed
    mov x27, #0
    bl capture
    bl compare
    mov x19, x0
    cbz x19, initial_ok
    add x27, x27, #1
    adrp x10, initial_failure
    add x10, x10, :lo12:initial_failure
    bl print_string
    mov x0, x19
    bl print_hex
initial_ok:
#if PERF_ONLY
    b benchmark
#else
#if ROOT_PROBE
    adrp x0, child_path
    add x0, x0, :lo12:child_path
    mov x1, #16
    mov x2, #0
    mov x3, #0
    mov x8, #6
    svc #0
    cbz x0, spawn_failure
    cmn x0, #1
    b.eq spawn_failure
#endif

    // Different values in every low/high half, distinct in each process.
    mov x9, #0
#if ROOT_PROBE
    movz x12, #0x1357
    movk x12, #0xACE1, lsl #16
    movk x12, #0x5A3C, lsl #32
    movk x12, #0xB179, lsl #48
#else
    movz x12, #0x8642
    movk x12, #0xEC02, lsl #16
    movk x12, #0xC3A5, lsl #32
    movk x12, #0x4E86, lsl #48
#endif
fill_expected:
    eor x13, x12, x9
    str x13, [x25, x9, lsl #3]
    add x9, x9, #1
    cmp x9, #64
    b.ne fill_expected
    mov x22, #0

phase_start:
    mov x21, #0
    mov x20, #512
    cmp x22, #1
    b.ne 1f
    mov x20, #256
1:
    cmp x22, #2
    b.ne 2f
    mov x20, #4
2:
    cmp x22, #3
    b.ne 3f
    mov x20, #8
3:
    mov x19, #0
phase_loop:
#if ROOT_PROBE
    add x23, x21, #1
    add x24, x21, #7
#else
    add x23, x21, #2
    add x24, x21, #13
#endif
    // Exercise RMode, FZ, DN, AHP and every cumulative status flag, without
    // requesting exception-enable bits that Cortex-A53 implements as RAZ/WI.
    and x23, x23, #31
    lsl x23, x23, #22
    and x12, x24, #32
    lsl x12, x12, #2
    and x13, x24, #64
    lsl x13, x13, #21
    and x24, x24, #31
    orr x24, x24, x12
    orr x24, x24, x13
    str x23, [x25, #512]
    str x24, [x25, #520]
    bl load_expected
    cmp x22, #1
    b.eq yield_step
    cmp x22, #2
    b.eq timer_step
    cmp x22, #3
    b.eq sleep_step
    mov x8, #3
    svc #0
    b check_step
yield_step:
    mov x8, #1
    svc #0
    b check_step
timer_step:
    mrs x12, cntfrq_el0
    lsr x12, x12, #2
    mrs x28, cntvct_el0
4:
    mrs x13, cntvct_el0
    sub x13, x13, x28
    cmp x13, x12
    b.lo 4b
    b check_step
sleep_step:
    mov x0, #1
    mov x8, #9
    svc #0
check_step:
    bl capture
    bl compare
    cbz x0, checked_ok
    cbnz x19, checked_ok
    mov x19, x0
checked_ok:
    add x21, x21, #1
    cmp x21, x20
    b.ne phase_loop

    adrp x10, phase_prefix
    add x10, x10, :lo12:phase_prefix
    bl print_string
    mov x0, x22
    bl print_hex
    cbz x19, phase_ok
    add x27, x27, #1
    adrp x10, failed_word
    add x10, x10, :lo12:failed_word
    bl print_string
    mov x0, x19
    bl print_hex
phase_ok:
    add x22, x22, #1
    cmp x22, #4
    b.ne phase_start
#if ROOT_PROBE
    // Test the actual split path: its child resumes this exact instruction
    // stream from the copied context, without running any fresh entry code.
    bl load_expected
    mov x8, #7
    svc #0
    mov x18, x0
    bl capture
    bl compare
    mov x19, x0
    cmn x18, #1
    b.eq split_creation_failed
    cbnz x19, split_state_failed
    cbz x18, split_child_ok
    adrp x10, split_parent_pass
    add x10, x10, :lo12:split_parent_pass
    bl print_string
    b split_done
split_child_ok:
    adrp x10, split_child_pass
    add x10, x10, :lo12:split_child_pass
    bl print_string
    b stopped
split_state_failed:
    add x27, x27, #1
    cbz x18, split_child_bad
    adrp x10, split_parent_fail
    add x10, x10, :lo12:split_parent_fail
    bl print_string
    mov x0, x19
    bl print_hex
    b split_done
split_child_bad:
    adrp x10, split_child_fail
    add x10, x10, :lo12:split_child_fail
    bl print_string
    mov x0, x19
    bl print_hex
    b stopped
split_creation_failed:
    add x27, x27, #1
    adrp x10, split_create_fail
    add x10, x10, :lo12:split_create_fail
    bl print_string
split_done:
#endif
    cbnz x27, test_failure
    adrp x10, pass_message
    add x10, x10, :lo12:pass_message
    bl print_string
    b stopped
spawn_failure:
    adrp x10, spawn_message
    add x10, x10, :lo12:spawn_message
    bl print_string
    b stopped
test_failure:
    adrp x10, failure_message
    add x10, x10, :lo12:failure_message
    bl print_string
stopped:
    mov x8, #1
    svc #0
    b stopped
#endif

// Capture/compare uses GPRs only, including both 64-bit halves of every Q.
capture:
    stp q0, q1, [x26, #0]
    stp q2, q3, [x26, #32]
    stp q4, q5, [x26, #64]
    stp q6, q7, [x26, #96]
    stp q8, q9, [x26, #128]
    stp q10, q11, [x26, #160]
    stp q12, q13, [x26, #192]
    stp q14, q15, [x26, #224]
    stp q16, q17, [x26, #256]
    stp q18, q19, [x26, #288]
    stp q20, q21, [x26, #320]
    stp q22, q23, [x26, #352]
    stp q24, q25, [x26, #384]
    stp q26, q27, [x26, #416]
    stp q28, q29, [x26, #448]
    stp q30, q31, [x26, #480]
    mrs x9, fpcr
    mrs x10, fpsr
    str x9, [x26, #512]
    str x10, [x26, #520]
    ret

load_expected:
    ldp q0, q1, [x25, #0]
    ldp q2, q3, [x25, #32]
    ldp q4, q5, [x25, #64]
    ldp q6, q7, [x25, #96]
    ldp q8, q9, [x25, #128]
    ldp q10, q11, [x25, #160]
    ldp q12, q13, [x25, #192]
    ldp q14, q15, [x25, #224]
    ldp q16, q17, [x25, #256]
    ldp q18, q19, [x25, #288]
    ldp q20, q21, [x25, #320]
    ldp q22, q23, [x25, #352]
    ldp q24, q25, [x25, #384]
    ldp q26, q27, [x25, #416]
    ldp q28, q29, [x25, #448]
    ldp q30, q31, [x25, #480]
    ldr x9, [x25, #512]
    ldr x10, [x25, #520]
    msr fpcr, x9
    msr fpsr, x10
    ret

compare:
    mov x9, #0
5:
    ldr x10, [x25, x9, lsl #3]
    ldr x11, [x26, x9, lsl #3]
    cmp x10, x11
    b.ne mismatch
    add x9, x9, #1
    cmp x9, #66
    b.ne 5b
    mov x0, #0
    ret
mismatch:
    add x0, x9, #1
    ret

// Helpers have a deliberately GPR-only implementation. Syscalls occur after capture.
print_string:
    mov x15, x30
6:
    ldrb w0, [x10], #1
    cbz w0, 7f
    mov x8, #2
    svc #0
    b 6b
7:
    mov x30, x15
    ret

print_hex:
    mov x14, x0
    mov x16, x30
    mov x17, #60
8:
    lsr x0, x14, x17
    and x0, x0, #15
    cmp x0, #10
    b.lo 9f
    add x0, x0, #87
    b 10f
9:
    add x0, x0, #48
10:
    mov x8, #2
    svc #0
    subs x17, x17, #4
    b.ge 8b
    mov x0, #10
    mov x8, #2
    svc #0
    mov x30, x16
    ret

#if PERF_ONLY
benchmark:
    mov x22, #0
    // Each line is one sample of 10,000 syscalls measured with CNTVCT_EL0.
bench_kind:
    mov x21, #0
bench_sample:
    mov x20, #10000
    mrs x28, cntvct_el0
11:
    mov x8, #3
    cbz x22, 12f
    mov x8, #1
12:
    svc #0
    subs x20, x20, #1
    b.ne 11b
    mrs x19, cntvct_el0
    sub x19, x19, x28
    adrp x10, bench_prefix
    add x10, x10, :lo12:bench_prefix
    bl print_string
    mov x0, x22
    bl print_hex
    adrp x10, ticks_prefix
    add x10, x10, :lo12:ticks_prefix
    bl print_string
    mov x0, x19
    bl print_hex
    add x21, x21, #1
    cmp x21, #21
    b.ne bench_sample
    add x22, x22, #1
    cmp x22, #2
    b.ne bench_kind
    adrp x10, bench_done
    add x10, x10, :lo12:bench_done
    bl print_string
13:
    b 13b
#endif

.section .rodata
child_path: .asciz "StorageCheck.elf"
#if ROOT_PROBE
initial_failure: .asciz "[ FP RAW root INITIAL FAIL ] word="
phase_prefix: .asciz "[ FP RAW root phase ] "
failed_word: .asciz "[ FP RAW root MISMATCH ] word="
pass_message: .asciz "[ FP RAW root PASS ]\n"
failure_message: .asciz "[ FP RAW root FAIL ]\n"
#else
initial_failure: .asciz "[ FP RAW child INITIAL FAIL ] word="
phase_prefix: .asciz "[ FP RAW child phase ] "
failed_word: .asciz "[ FP RAW child MISMATCH ] word="
pass_message: .asciz "[ FP RAW child PASS ]\n"
failure_message: .asciz "[ FP RAW child FAIL ]\n"
#endif
spawn_message: .asciz "[ FP RAW SPAWN FAIL ]\n"
split_parent_pass: .asciz "[ FP RAW split parent PASS ]\n"
split_child_pass: .asciz "[ FP RAW split child PASS ]\n"
split_parent_fail: .asciz "[ FP RAW split parent FAIL ] word="
split_child_fail: .asciz "[ FP RAW split child FAIL ] word="
split_create_fail: .asciz "[ FP RAW split CREATE FAIL ]\n"
bench_prefix: .asciz "FP_BENCH kind="
ticks_prefix: .asciz "FP_TICKS value="
bench_done: .asciz "[ FP BENCH DONE ]\n"
.section .bss
.balign 16
expected: .skip 528
.balign 16
observed: .skip 528

