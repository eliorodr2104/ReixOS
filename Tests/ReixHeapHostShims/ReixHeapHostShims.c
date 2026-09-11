#include "ReixHeapHostShims.h"

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

enum {
    reix_syscall_brk      = 11,
    reix_syscall_mmap     = 12,
    reix_syscall_munmap   = 13,
    reix_syscall_decommit = 14,
};

enum {
    reix_page_size  = 4096,
    reix_arena_pages = 64,
};

static _Alignas(reix_page_size) unsigned char arena[reix_arena_pages * reix_page_size];
static _Alignas(reix_page_size) unsigned char large_arena[4 * reix_page_size];
static uintptr_t current_break;
static uint64_t syscall_count;
static uint64_t decommit_count;
static uint64_t decommit_failures;
static int zero_next_break_query;
static int malformed_next_break_query;
static int malformed_query_after_next_growth;
static uint64_t break_set_count;
static uint64_t munmap_count;
static uint64_t munmap_failures;
static int large_mapping_enabled;
static uint64_t large_mapping_size;

void reix_heap_host_reset(void) {
    current_break = (uintptr_t)arena;
    syscall_count = 0;
    decommit_count = 0;
    decommit_failures = 0;
    zero_next_break_query = 0;
    malformed_next_break_query = 0;
    malformed_query_after_next_growth = 0;
    break_set_count = 0;
    munmap_count = 0;
    munmap_failures = 0;
    large_mapping_enabled = 0;
    large_mapping_size = 0;
}

void reix_heap_host_enable_large_mapping(void) { large_mapping_enabled = 1; }
void reix_heap_host_fail_munmap(uint64_t count) { munmap_failures = count; }
uint64_t reix_heap_host_munmap_count(void) { return munmap_count; }

void reix_heap_host_fail_decommit(uint64_t count) {
    decommit_failures = count;
}

void reix_heap_host_zero_next_break_query(void) {
    zero_next_break_query = 1;
}

void reix_heap_host_malformed_next_break_query(void) {
    malformed_next_break_query = 1;
}

void reix_heap_host_malformed_query_after_next_growth(void) {
    malformed_query_after_next_growth = 1;
}

uint64_t reix_heap_host_syscall_count(void) {
    return syscall_count;
}

uint64_t reix_heap_host_decommit_count(void) {
    return decommit_count;
}

uint64_t reix_heap_host_break_set_count(void) {
    return break_set_count;
}

uint64_t reix_heap_host_break_offset(void) {
    return (uint64_t)(current_break - (uintptr_t)arena);
}

uint64_t _asm_syscall(
    uint64_t number,
    uint64_t arg1,
    uint64_t arg2,
    uint64_t arg3,
    uint64_t arg4,
    uint64_t arg5,
    uint64_t arg6,
    uint64_t arg7
) {
    (void)arg3;
    (void)arg4;
    (void)arg5;
    (void)arg6;
    (void)arg7;
    syscall_count += 1;

    if (number == reix_syscall_brk) {
        if (arg1 == 0) {
            if (zero_next_break_query) {
                zero_next_break_query = 0;
                return 0;
            }
            if (malformed_next_break_query) {
                malformed_next_break_query = 0;
                return UINT64_MAX;
            }
            return (uint64_t)current_break;
        }

        const uintptr_t base = (uintptr_t)arena;
        const uintptr_t end = base + sizeof(arena);
        if (arg1 < base || arg1 > end || ((arg1 - base) & (reix_page_size - 1)) != 0) {
            return UINT64_MAX;
        }

        current_break = (uintptr_t)arg1;
        break_set_count += 1;
        if (malformed_query_after_next_growth) {
            malformed_query_after_next_growth = 0;
            malformed_next_break_query = 1;
        }
        return (uint64_t)current_break;
    }

    if (number == reix_syscall_decommit) {
        decommit_count += 1;
        if (decommit_failures > 0) {
            decommit_failures -= 1;
            return UINT64_MAX;
        }
        return 0;
    }

    if (number == reix_syscall_mmap) {
        if (!large_mapping_enabled || arg1 == 0 || arg1 > sizeof(large_arena)
            || large_mapping_size != 0) {
            return 0;
        }
        large_mapping_size = arg1;
        return (uint64_t)(uintptr_t)large_arena;
    }

    if (number == reix_syscall_munmap) {
        munmap_count += 1;
        if (munmap_failures > 0) {
            munmap_failures -= 1;
            return UINT64_MAX;
        }
        if (arg1 != (uint64_t)(uintptr_t)large_arena || arg2 != large_mapping_size
            || large_mapping_size == 0) {
            return UINT64_MAX;
        }
        large_mapping_size = 0;
        return 0;
    }

    return UINT64_MAX;
}

uint64_t _asm_call(uint64_t number, ...) {
    (void)number;
    return UINT64_MAX;
}

uint64_t _asm_recv(uint64_t number, ...) {
    (void)number;
    return UINT64_MAX;
}

uint64_t _asm_recv_timeout(uint64_t number, ...) {
    (void)number;
    return UINT64_MAX;
}

uint64_t _asm_spawn(uint64_t number, ...) {
    (void)number;
    return UINT64_MAX;
}

void dmb_ish(void) {}
uint64_t reix_pmu_cycles(void) { return 0; }
uint64_t reix_pmu_event0(void) { return 0; }
