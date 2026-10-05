// C allocation spellings expected by Embedded Swift in each user process.
// The user heap implementation and policy remain in Swift under unique names.

typedef __SIZE_TYPE__ size_t;

extern void *reix_malloc(size_t size);
extern void reix_free(void *pointer);
extern int reix_posix_memalign(void **output, size_t alignment, size_t size);

void *malloc(size_t size) {
    return reix_malloc(size);
}

void free(void *pointer) {
    reix_free(pointer);
}

int posix_memalign(void **output, size_t alignment, size_t size) {
    return reix_posix_memalign(output, alignment, size);
}
