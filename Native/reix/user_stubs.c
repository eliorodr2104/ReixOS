//
//  user_stubs.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

#include <stdint.h>
#include <stddef.h>

// --- Stack Protector ---
// Il compilatore inserisce questi controlli per sicurezza.
uintptr_t __stack_chk_guard = 0xDEADC0DE;

void __stack_chk_fail(void) {
    while (1); // Blocco totale se lo stack è corrotto
}

// --- Utility ---
// Il compilatore genera spesso chiamate a memset per azzerare le struct
void* memset(void* s, int c, size_t n) {
    unsigned char* p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

// Under -mstrict-align the compiler emits memcpy/memmove calls for struct copies
// (instead of unaligned SIMD load/store). Userland runs with the MMU on, so a
// byte-wise copy is sufficient and always correct.
void* memcpy(void* dst, const void* src, size_t n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void* memmove(void* dst, const void* src, size_t n) {
    unsigned char* d = dst;
    const unsigned char* s = src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else if (d > s) {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}
