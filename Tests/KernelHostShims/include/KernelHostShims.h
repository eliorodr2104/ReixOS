#include <stdint.h>

uint64_t page_table_barrier_count(void);
void reset_page_table_barrier_count(void);

uint64_t dcache_clean_calls(void);
uint64_t dcache_cleaned_base(void);
uint64_t dcache_cleaned_size(void);
void reset_dcache_clean_record(void);

// The ordered record of the page-table ordering shims. `mmu_trace_reset` takes
// the descriptor to sample at every call, or NULL for none.
enum MMUTraceOp {
    MMU_OP_PAGE_TABLE_BARRIER     = 1,
    MMU_OP_TLB_SYNC               = 4,
    MMU_OP_TLB_ALL                = 5,
    MMU_OP_INSTRUCTION_BARRIER    = 6,
    MMU_OP_TLB_ASID               = 7,  // arg: the ASID
    MMU_OP_TLB_LEAF               = 8,  // arg: VA[55:12] | ASID << 48
    MMU_OP_TLB_TABLE              = 9,  // arg: VA[55:12] | ASID << 48
    MMU_OP_DCACHE_CLEAN_POU       = 10, // arg, size, line: the range
    MMU_OP_ICACHE_LINES           = 11, // arg, size, line: the range
    MMU_OP_ICACHE_ALL             = 12,
    MMU_OP_INSTRUCTION_STREAM     = 13,
    MMU_OP_DCACHE_CLEAN_POC       = 14, // arg, size, line: the range
};
void mmu_trace_reset(const uint64_t *probe);
uint64_t mmu_trace_length(void);
uint32_t mmu_trace_op(uint64_t index);
uint64_t mmu_trace_arg(uint64_t index);
uint64_t mmu_trace_size(uint64_t index);
uint64_t mmu_trace_line(uint64_t index);
uint64_t mmu_trace_descriptor(uint64_t index);

// CTR_EL0 as `read_cache_type` answers it. Zero until set.
void host_set_cache_type(uint64_t value);

// MIDR_EL1 as `read_main_id` answers it. Zero until set.
void host_set_main_id(uint64_t value);
uint64_t host_main_id_reads(void);

// The generic timer as a suite stages it: counter, tick compare value and
// frequency. All three read zero until set, as they always have.
void host_set_virtual_counter(uint64_t value);
void host_set_timer_deadline(uint64_t value);
void host_set_counter_frequency(uint64_t value);

void kernel_host_shims_link_anchor(void);

void host_set_interrupt_window_hook(void (*hook)(void));
void host_set_serial_write_hook(uint8_t (*hook)(uint8_t));
void host_set_data_barrier_hook(void (*hook)(void));
void dmb_ish(void);

// Read host nanoseconds for latency measurements, zero disables it.
void host_use_monotonic_counter(int enabled);
