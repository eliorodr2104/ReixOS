//  AsmSyscall.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

.global _asm_syscall
.global _asm_syscall_ptr

_asm_syscall:
    // x0: syscall number
    // x1: arg1
    // x2: arg2
    // x3: arg3
    // x4: arg4
    // x5: arg5
    // x6: arg6
    // x7: arg7
    
    mov x8, x0 // Move to x8, because ARM need syscall number in x8 reg

    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x6, x7
    
    svc #0
    ret


_asm_syscall_ptr:
    // x0: syscall number
    // x1: ptr
    // x2: size
    
    mov x8, x0 // Move to x8, because ARM need syscall number in x8 reg

    mov x0, x1
    mov x1, x2
    
    svc #0
    ret
