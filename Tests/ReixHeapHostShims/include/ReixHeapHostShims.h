#ifndef REIX_HEAP_HOST_SHIMS_H
#define REIX_HEAP_HOST_SHIMS_H

#include <stdint.h>

void reix_heap_host_reset(void);
void reix_heap_host_fail_decommit(uint64_t count);
void reix_heap_host_zero_next_break_query(void);
void reix_heap_host_malformed_next_break_query(void);
void reix_heap_host_malformed_query_after_next_growth(void);
uint64_t reix_heap_host_syscall_count(void);
uint64_t reix_heap_host_decommit_count(void);
uint64_t reix_heap_host_break_set_count(void);
uint64_t reix_heap_host_break_offset(void);

#endif
