// EL0 oracle for the first stack page installed by ProcessManager.spawnProcess(path:).
//
// The scan starts at the first instruction and uses only registers. No call,
// push, spill, Swift prologue, or store touches the stack before all 4096 bytes
// have been checked.
.text
.align 4
.global _start
_start:
    sub x19, sp, #1, lsl #12
    mov x20, #0
    mov x21, #0

.L_scan:
    ldrb w22, [x19, x20]
    cbz w22, .L_next
    add x21, x21, #1
.L_next:
    add x20, x20, #1
    cmp x20, #1, lsl #12
    b.ne .L_scan

    cbnz x21, .L_failed
    adrp x10, pass_message
    add  x10, x10, :lo12:pass_message
    bl print_string
    b .L_stopped

.L_failed:
    adrp x10, failure_message
    add  x10, x10, :lo12:failure_message
    bl print_string

.L_stopped:
    mov x8, #1
    svc #0
    b .L_stopped


print_string:
    mov x15, x30
.L_print_byte:
    ldrb w0, [x10], #1
    cbz w0, .L_print_done
    mov x8, #2
    svc #0
    b .L_print_byte
.L_print_done:
    mov x30, x15
    ret


.section .rodata
pass_message:    .asciz "[ PAGE ZERO PASS ] bytes=4096\n"
failure_message: .asciz "[ PAGE ZERO FAIL ] nonzero-stack-byte\n"
