//  mem.S
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

.section .text
.global memcpy
.global memset
.global memmove
.global memcmp

// --- memcpy (x0: dest, x1: src, x2: n) ---
// Return: x0
memcpy:
    mov x3, x0
.Lmemcpy_16:
    cmp x2, #16
    b.lo .Lmemcpy_1
    ldp x4, x5, [x1], #16    // Load 16 byte to src
    stp x4, x5, [x3], #16    // Save 16 byte in dest
    sub x2, x2, #16
    b .Lmemcpy_16
.Lmemcpy_1:
    cbz x2, .Lmemcpy_done
    ldrb w4, [x1], #1
    strb w4, [x3], #1
    sub x2, x2, #1
    b .Lmemcpy_1
.Lmemcpy_done:
    ret

// --- memset (x0: s, x1: c, x2: n) ---
// Return x0
memset:
    mov x3, x0
    and w1, w1, #0xff

    orr w1, w1, w1, lsl #8
    orr w1, w1, w1, lsl #16
    orr x1, x1, x1, lsl #32
.Lmemset_16:
    cmp x2, #16
    b.lo .Lmemset_1
    stp x1, x1, [x3], #16
    sub x2, x2, #16
    b .Lmemset_16
.Lmemset_1:
    cbz x2, .Lmemset_done
    strb w1, [x3], #1
    sub x2, x2, #1
    b .Lmemset_1
.Lmemset_done:
    ret

// --- memmove (x0: dest, x1: src, x2: n) ---
memmove:
    cmp x0, x1
    b.eq .Lmove_done
    b.lo memcpy
    
    // Se dest > src, dobbiamo copiare dalla fine all'inizio
    add x3, x0, x2
    add x4, x1, x2
.Lmove_back:
    cbz x2, .Lmove_done
    ldrb w5, [x4, #-1]!
    strb w5, [x3, #-1]!
    sub x2, x2, #1
    b .Lmove_back
.Lmove_done:
    ret

// --- memcmp (x0: s1, x1: s2, x2: n) ---
// Ritorna 0 se uguali, <0 o >0 altrimenti
memcmp:
    cbz x2, .Lcmp_zero
.Lcmp_loop:
    ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    subs w3, w3, w4
    b.ne .Lcmp_diff
    subs x2, x2, #1
    b.ne .Lcmp_loop
.Lcmp_zero:
    mov x0, #0
    ret
.Lcmp_diff:
    sxtw x0, w3              
    ret
