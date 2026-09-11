#include <stdint.h>

uint64_t page_table_barrier_count(void);
void reset_page_table_barrier_count(void);

uint64_t dcache_clean_calls(void);
uint64_t dcache_cleaned_base(void);
uint64_t dcache_cleaned_size(void);
void reset_dcache_clean_record(void);
uint64_t instruction_cache_sync_calls(void);
uint64_t instruction_cache_synced_base(void);
uint64_t instruction_cache_synced_size(void);
void reset_instruction_cache_sync_record(void);

// The ordered record of the page-table ordering shims. `mmu_trace_reset` takes
// the descriptor to sample at every call, or NULL for none.
//
// Op codes: 1 page_table_barrier, 2 flush_tlb_page, 3 flush_tlb_page_nosync,
// 4 flush_tlb_sync, 5 flush_tlb, 6 instruction_barrier.
void mmu_trace_reset(const uint64_t *probe);
uint64_t mmu_trace_length(void);
uint32_t mmu_trace_op(uint64_t index);
uint64_t mmu_trace_arg(uint64_t index);
uint64_t mmu_trace_descriptor(uint64_t index);

void kernel_host_shims_link_anchor(void);
