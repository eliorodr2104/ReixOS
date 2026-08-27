#include <stdint.h>

uint64_t page_table_barrier_count(void);
void reset_page_table_barrier_count(void);

uint64_t dcache_clean_calls(void);
uint64_t dcache_cleaned_base(void);
uint64_t dcache_cleaned_size(void);
void reset_dcache_clean_record(void);
