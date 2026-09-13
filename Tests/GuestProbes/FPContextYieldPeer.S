// Two-process context-switch benchmark for the full FP/SIMD trap frame.
//
// The Init image measures 21 batches of 10,000 voluntary round trips. Its
// StorageCheck peer does nothing except yield back, so every measured iteration
// contains at least two real process transitions and no application work;
// timer preemption may add more. QEMU icount makes the result a deterministic
// virtual instruction cost, not a hardware or wall-clock performance claim.
.text
.align 4
.global _start
_start:
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

    // Bring the peer to its yield loop before taking the first sample.
    mov x20, #64
warmup:
    mov x8, #1
    svc #0
    subs x20, x20, #1
    b.ne warmup

    mov x21, #0
sample:
    mov x20, #10000
    mrs x28, cntvct_el0
measure:
    mov x8, #1
    svc #0
    subs x20, x20, #1
    b.ne measure
    mrs x19, cntvct_el0
    sub x19, x19, x28

    adrp x10, ticks_prefix
    add x10, x10, :lo12:ticks_prefix
    bl print_string
    mov x0, x19
    bl print_hex

    add x21, x21, #1
    cmp x21, #21
    b.ne sample

    adrp x10, done_message
    add x10, x10, :lo12:done_message
    bl print_string
stopped:
    b stopped

spawn_failure:
    adrp x10, spawn_message
    add x10, x10, :lo12:spawn_message
    bl print_string
    b stopped
#else
    adrp x10, peer_ready
    add x10, x10, :lo12:peer_ready
    bl print_string
peer_yield:
    mov x8, #1
    svc #0
    b peer_yield
#endif

// Printing stays outside every measured interval and uses GPRs only.
print_string:
    mov x15, x30
1:
    ldrb w0, [x10], #1
    cbz w0, 2f
    mov x8, #2
    svc #0
    b 1b
2:
    mov x30, x15
    ret

#if ROOT_PROBE
print_hex:
    mov x14, x0
    mov x16, x30
    mov x17, #60
3:
    lsr x0, x14, x17
    and x0, x0, #15
    cmp x0, #10
    b.lo 4f
    add x0, x0, #87
    b 5f
4:
    add x0, x0, #48
5:
    mov x8, #2
    svc #0
    subs x17, x17, #4
    b.ge 3b
    mov x0, #10
    mov x8, #2
    svc #0
    mov x30, x16
    ret

.section .rodata
child_path: .asciz "StorageCheck.elf"
ticks_prefix: .asciz "FP_PEER_TICKS value="
done_message: .asciz "[ FP PEER BENCH DONE ]\n"
spawn_message: .asciz "[ FP PEER BENCH SPAWN FAIL ]\n"
#endif
peer_ready: .asciz "[ FP PEER READY ]\n"
