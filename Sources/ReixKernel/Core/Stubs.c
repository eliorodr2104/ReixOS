//
//  Stubs.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/04/2026.
//

#include <stdint.h>
#include <stddef.h>

// --- Protezione Stack ---
// Un valore casuale per il canarino (puoi cambiarlo all'avvio per sicurezza)
uintptr_t __stack_chk_guard = 0x595e9fbd394d2c87;

// Funzione chiamata se lo stack è corrotto
void __stack_chk_fail(void) {
    // In un kernel serio, qui chiameresti un 'panic'
    while (1) {
        __asm__ volatile("wfi");
    }
}

// --- Gestione Memoria (Temporanea) ---
void free(void *ptr) {
    // Per ora non facciamo nulla
}

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    // Inizialmente puoi restituire un errore (es. ENOMEM)
    // o implementare un'allocazione statica temporanea.
    return -1;
}

// --- Entropia (Random) ---
void arc4random_buf(void *buf, size_t nbytes) {
    uint8_t *p = (uint8_t *)buf;
    for (size_t i = 0; i < nbytes; i++) {
        p[i] = 0x42; // Un valore "casuale" molto prevedibile per ora
    }
}
