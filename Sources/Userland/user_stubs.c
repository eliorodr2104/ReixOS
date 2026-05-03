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

// --- Memory Management ---
// Per ora le app non hanno un heap (malloc/free).
// Li stubbiamo a vuoto o a errore.
void free(void *ptr) {
    // Nulla da fare
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    return -1; // Ritorna errore (niente memoria)
}

// --- Utility ---
// Il compilatore genera spesso chiamate a memset per azzerare le struct
void* memset(void* s, int c, size_t n) {
    unsigned char* p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}
