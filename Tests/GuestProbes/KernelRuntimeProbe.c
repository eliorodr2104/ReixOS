// Calls the actual C runtime symbols without declaring reserved names in Swift.

typedef __SIZE_TYPE__ size_t;

extern void *malloc(size_t size);
extern void free(void *pointer);
extern int posix_memalign(void **output, size_t alignment, size_t size);
extern void arc4random_buf(void *buffer, size_t count);
extern size_t __stack_chk_guard;

void *reix_runtime_probe_malloc(size_t size) {
    return malloc(size);
}

void reix_runtime_probe_free(void *pointer) {
    free(pointer);
}

int reix_runtime_probe_posix_memalign(
    void **output,
    size_t alignment,
    size_t size
) {
    return posix_memalign(output, alignment, size);
}

void reix_runtime_probe_arc4random_buf(void *buffer, size_t count) {
    arc4random_buf(buffer, count);
}

__attribute__((noinline))
void reix_runtime_probe_stack_check(void) {
    volatile unsigned char frame[32];
    frame[0] = 0x5A;

    // The function prologue has already saved the old guard. Changing the
    // current guard makes the compiler-generated epilogue call
    // __stack_chk_fail; a direct call would only test the handler.
    __stack_chk_guard ^= (size_t)1;

    if (frame[0] != 0x5A) {
        __builtin_trap();
    }
}
