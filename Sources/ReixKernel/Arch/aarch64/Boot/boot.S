//
//  Boot.s
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

.equ SPSR_EL1h,  (0b0101)
.equ SPSR_DAIF,  (0b1111 << 6)
.equ SPSR_VALUE, (SPSR_EL1h | SPSR_DAIF)   // 0x3C5

.section .text.boot
.global _start

_start:
    mov     x21, x0
    
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbz     x0, .L_master_core

.L_parking_loop:
    wfe
    b       .L_parking_loop

.L_master_core:
    adr     x20, _start
    ldr     x19, =_start
    sub     x19, x20, x19

    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #2
    b.eq    .L_drop_to_el1
    b       .L_setup_el1

.L_drop_to_el1:
    msr     cptr_el2, xzr
    
    mov     x0, #0x3
    msr     cnthctl_el2, x0
    
    msr     cntvoff_el2, xzr

    mov     x0, #(1 << 31)
    msr     hcr_el2, x0

    ldr     x0, =SPSR_VALUE
    msr     spsr_el2, x0

    adr     x1, .L_setup_el1
    msr     elr_el2, x1
    eret

.L_setup_el1:
    ldr     x0, =stack_top
    add     x0, x0, x19
    mov     sp, x0

    adr     x0, _evt_start
    msr     vbar_el1, x0
    
    mrs     x0, cntkctl_el1
    orr     x0, x0, #0x3
    msr     cntkctl_el1, x0

    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    ldr     x2, =__bss_start
    add     x2, x2, x19
    ldr     x3, =__bss_end
    add     x3, x3, x19

.L_bss_loop:
    cmp     x2, x3
    b.hs    .L_jump_to_swift
    str     xzr, [x2], #8
    b       .L_bss_loop

.L_jump_to_swift:
    mov     x29, #0
    mov     x30, #0
    mov     x0, x21                 
    bl      kernel_main
