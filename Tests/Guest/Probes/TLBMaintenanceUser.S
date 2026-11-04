// EL0 oracle for the TLB maintenance of a clone's downgrade and of an unmap.
//
// Runs as init. Every check reads memory through a translation the kernel has
// just changed, right after the change, with no syscall in between that could
// switch address spaces: QEMU drops its whole soft TLB on an ASID switch, so a
// missing invalidation only shows while the same space keeps running.
//
// Syscalls: 1 yield, 2 putchar, 7 split, 12 mmap, 13 munmap.
.text
.align 4
.global _start
_start:
    // P: one anonymous page, written so the TLB holds a writable entry for it.
    mov  x0, #4096
    mov  x8, #12
    svc  #0
    cbz  x0, .L_setup_failed
    mov  x19, x0
    mov  w20, #0x41
    strb w20, [x19]
    ldrb w21, [x19]

    mov  x8, #7
    svc  #0
    cmn  x0, #1
    b.eq .L_setup_failed
    cbz  x0, .L_child

    // The parent's first store after the clone. The clone made P read-only
    // here, so this has to fault into a private copy and leave the child's alone.
    mov  w20, #0x42
    strb w20, [x19]

.L_parent_idle:
    mov  x8, #1
    svc  #0
    b    .L_parent_idle

.L_child:
    // Let the parent run its store first, whatever the scheduler picked.
    mov  x22, #8
.L_child_wait:
    mov  x8, #1
    svc  #0
    subs x22, x22, #1
    b.ne .L_child_wait

    ldrb w21, [x19]
    cmp  w21, #0x41
    b.ne .L_cow_failed

    adrp x10, cow_pass
    add  x10, x10, :lo12:cow_pass
    bl   print_string

    adrp x10, unmap_probe
    add  x10, x10, :lo12:unmap_probe
    bl   print_string

    // Q: one more page, touched, unmapped, then read straight away.
    mov  x0, #4096
    mov  x8, #12
    svc  #0
    cbz  x0, .L_setup_failed
    mov  x23, x0
    mov  w20, #0x51
    strb w20, [x23]
    ldrb w21, [x23]

    mov  x0, x23
    mov  x1, #4096
    mov  x8, #13
    svc  #0
    cbnz x0, .L_setup_failed

    // Must fault. Reaching the next line means the translation outlived munmap.
    ldrb w21, [x23]

    adrp x10, unmap_fail
    add  x10, x10, :lo12:unmap_fail
    bl   print_string
    b    .L_stopped

.L_cow_failed:
    adrp x10, cow_fail
    add  x10, x10, :lo12:cow_fail
    bl   print_string
    b    .L_stopped

.L_setup_failed:
    adrp x10, setup_fail
    add  x10, x10, :lo12:setup_fail
    bl   print_string

.L_stopped:
    mov  x8, #1
    svc  #0
    b    .L_stopped


print_string:
    mov  x15, x30
.L_print_byte:
    ldrb w0, [x10], #1
    cbz  w0, .L_print_done
    mov  x8, #2
    svc  #0
    b    .L_print_byte
.L_print_done:
    mov  x30, x15
    ret


.section .rodata
cow_pass:    .asciz "[ TLB COW PASS ] the parent's write after the clone stayed its own\n"
cow_fail:    .asciz "[ TLB COW FAIL ] the parent wrote through a stale writable entry\n"
unmap_probe: .asciz "[ TLB UNMAP PROBE ] reading a page after munmap\n"
unmap_fail:  .asciz "[ TLB UNMAP FAIL ] a stale translation survived munmap\n"
setup_fail:  .asciz "[ TLB SETUP FAIL ]\n"
