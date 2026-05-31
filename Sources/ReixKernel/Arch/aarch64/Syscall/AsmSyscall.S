//  AsmSyscall.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

.global _asm_syscall
.global _asm_recv
.global _asm_call


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
    mov x5, x6
    mov x6, x7
    
    svc #0
    ret


_asm_recv:
    // x0: Syscall number
    // x1: Handle
    // x2: Output buffer ptr

    mov x8, x0
    mov x9, x2
    mov x0, x1

    svc #0

    // Return: x0 = status, x1 = tag, x2..x5=words, x6=badge
    str x1, [x9]        // buffer[0] = tag
    str x2, [x9, #8]    // buffer[1] = word0
    str x3, [x9, #16]   // buffer[2] = word1
    str x4, [x9, #24]   // buffer[3] = word2
    str x5, [x9, #32]   // buffer[4] = word3
    str x6, [x9, #40]   // buffer[5] = badge

    ret // x0 state


_asm_call:
    // x0: syscall number
    // x1: handle
    // x2: tag
    // x3: word0
    // x4: word1
    // x5: word2
    // x6: word3
    // x7: reply buffer ptr

    mov x8, x0      // syscall number in x8
    mov x9, x7      // save reply buffer ptr (survives the syscall)

    mov x0, x1      // handle
    mov x1, x2      // tag
    mov x2, x3      // word0
    mov x3, x4      // word1
    mov x4, x5      // word2
    mov x5, x6      // word3

    svc #0

    // Return: x0 = status, x1 = tag, x2..x5 = words, x6 = badge
    str x1, [x9]        // buffer[0] = tag
    str x2, [x9, #8]    // buffer[1] = word0
    str x3, [x9, #16]   // buffer[2] = word1
    str x4, [x9, #24]   // buffer[3] = word2
    str x5, [x9, #32]   // buffer[4] = word3
    str x6, [x9, #40]   // buffer[5] = badge

    ret // x0 status
