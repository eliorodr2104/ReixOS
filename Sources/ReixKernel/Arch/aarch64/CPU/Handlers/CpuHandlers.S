;
//  CpuHandlers.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

.section .text
.global disable_interrupts
.global wait_for_interrupt
.global enable_interrupts
.global nop
.global wait_for_exception
.global trigger_trap
.global jump_to_high_half
.global set_vbar
.global set_current_process
.global get_current_process


disable_interrupts:
    msr daifset, #3
    ret

enable_interrupts:
    msr daifclr, #3
    ret

wait_for_interrupt:
    wfi
    ret

nop:
    nop
    ret
    
wait_for_exception:
    wfe
    b wait_for_exception

trigger_trap:
    brk #0

jump_to_high_half:
    mov     x1, sp
    add     x1, x1, x0
    mov     sp, x1

    add     x30, x30, x0

    adr     x1, .L_trampoline_target
    add     x1, x1, x0
    
    br      x1

.L_trampoline_target:
    ret

set_vbar:
    msr vbar_el1, x0
    ret

set_current_process:
    msr tpidr_el1, x0
    ret

get_current_process:
    mrs x0, tpidr_el1
    ret
