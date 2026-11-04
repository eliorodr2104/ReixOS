// Exact freestanding ABI expected by Embedded Swift and compiler-generated code.
// The policy and allocator remain in Swift under unique, non-reserved symbols.

typedef __SIZE_TYPE__ size_t;
typedef __UINTPTR_TYPE__ uintptr_t;

extern void *reix_kernel_malloc(size_t size);
extern void reix_kernel_free(void *pointer);
extern int reix_kernel_posix_memalign(void **output, size_t alignment, size_t size);
extern void reix_kernel_stack_check_failed(void);
extern void reix_kernel_fill_deterministic_hash_seed(void *buffer, size_t count);

void *malloc(size_t size) {
    return reix_kernel_malloc(size);
}

void free(void *pointer) {
    reix_kernel_free(pointer);
}

int posix_memalign(void **output, size_t alignment, size_t size) {
    return reix_kernel_posix_memalign(output, alignment, size);
}

// Fixed canary detects corruption but provides no randomization or secrecy.
uintptr_t __stack_chk_guard = (uintptr_t)0x595e9fbd394d2c87ULL;

__attribute__((noreturn))
void __stack_chk_fail(void) {
    reix_kernel_stack_check_failed();
    __builtin_unreachable();
}

// Embedded Swift's Hasher requires this libc spelling. ReixOS currently has no
// CSPRNG, so the backend deliberately supplies a fixed compatibility seed only.
void arc4random_buf(void *buffer, size_t count) {
    reix_kernel_fill_deterministic_hash_seed(buffer, count);
}
