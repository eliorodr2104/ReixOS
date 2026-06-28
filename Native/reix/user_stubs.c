//
//  user_stubs.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

#include <stdint.h>
#include <stddef.h>

uintptr_t __stack_chk_guard = 0xDEADC0DE;

extern void reix_free(void* ptr);
extern void* reix_malloc(size_t size);
extern int32_t reix_posix_memalign(void** memptr, size_t alignment, size_t size);



void __stack_chk_fail(void) {
    while (1); // Blocco totale se lo stack è corrotto
}

void* memset(void* s, int c, size_t n) {
    unsigned char* p = s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

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


void arc4random_buf(void *buf, size_t nbytes) {
    unsigned char *p = (unsigned char *)buf;
    for (size_t i = 0; i < nbytes; i++) p[i] = 0x42;
}



void free(void* ptr) {
    reix_free(ptr);
}

void* malloc(size_t size) {
    return reix_malloc(size);
}

int posix_memalign(void** memptr, size_t alignment, size_t size) {
    return reix_posix_memalign(memptr, alignment, size);
}
