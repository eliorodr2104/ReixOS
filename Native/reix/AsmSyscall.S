//  AsmSyscall.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

.global _asm_syscall
.global _asm_recv
.global _asm_spawn
.global _asm_call
.global _asm_recv_timeout


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


_asm_spawn:
    // x0: syscall number
    // x1: path ptr
    // x2: length
    // x3: output buffer ptr

    mov x8, x0          // syscall number -> x8
    mov x9, x3          // save output buffer ptr (survives the svc)

    mov x0, x1          // path ptr -> kernel arg0 (x0)
    mov x1, x2          // length   -> kernel arg1 (x1)

    svc #0

    // Return from kernel: x0 = pid, x1 = handleEndpoint
    str x0, [x9]        // buffer[0] = pid
    str x1, [x9, #8]    // buffer[1] = handleEndpoint

    ret // x0 = pid (ignored; caller reads the buffer)


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
    str x7, [x9, #48]   // buffer[6] = grantHandle

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
    str x7, [x9, #48]   // buffer[6] = grantHandle

    ret // x0 status


_asm_recv_timeout:
    // x0: syscall number
    // x1: handle
    // x2: timeout ticks
    // x3: reply buffer ptr

    mov x8, x0      // syscall number in x8
    mov x9, x3      // save reply buffer ptr (survives the syscall)

    mov x0, x1      // handle
    mov x1, x2      // timeout ticks

    svc #0

    // Return: x0 = status, x1 = tag, x2..x5 = words, x6 = badge, x7 = grant
    str x1, [x9]        // buffer[0] = tag
    str x2, [x9, #8]    // buffer[1] = word0
    str x3, [x9, #16]   // buffer[2] = word1
    str x4, [x9, #24]   // buffer[3] = word2
    str x5, [x9, #32]   // buffer[4] = word3
    str x6, [x9, #40]   // buffer[5] = badge
    str x7, [x9, #48]   // buffer[6] = grantHandle

    ret // x0 status
