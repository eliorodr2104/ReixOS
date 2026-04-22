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
