//
//  KernelHostShims.c
//  ReixOS
//
//  Host stand-ins for the assembly the `reix` plugin generates for the machine, one
//  definition per `@_silgen_name` declaration in the kernel, plus the linker symbols
//  the kernel takes the address of. Behaviour is inert on purpose: the host suites
//  test Swift, not the instruction sequences.
//
//  Every parameter list here has to match the Swift declaration's and not merely
//  link. A Swift caller passes its arguments by the platform's call convention
//  whether the callee names them or not, so a `(void)` stand-in for a function that
//  takes arguments is inert only for as long as nobody writes a body that reads
//  them. That drift is what made `set_current_process` unimplementable as anything
//  but a no-op, and with it the current process unresolvable on the host, which put
//  every authority-checked syscall's success path out of reach.
//
//  The types come from the Swift side: `PhysicalAddress` and `VirtualAddress` are
//  `UInt64`, `ASID` is `UInt16`, and a Swift `Bool` return is one byte.
//

#include <stdint.h>
#include <string.h>
#include <time.h>

#include "include/KernelHostShims.h"

static uint64_t barrier_count;

// Stands in for TPIDR_EL1, which is where the machine keeps the running process.
// Stateful so a suite can install a caller and the syscalls can resolve it.
static uint64_t current_process;

unsigned char __exception_stack_bottom;
unsigned char __exception_stack_top;
unsigned char __stack_bottom;
unsigned char __stack_guard_bottom;
unsigned char __stack_guard_top;
unsigned char stack_top;
unsigned char _data_start;
unsigned char _evt_end;
unsigned char _initrd_end;
unsigned char _initrd_start;
unsigned char _kernel_end;
unsigned char _kernel_start;
unsigned char _kernel_total_end;
unsigned char _rodata_end;
unsigned char _rodata_start;
unsigned char _text_end;

void disable_interrupts(void) {}
void enable_core_timer(void) {}
static void (*interrupt_window_hook)(void);
void host_set_interrupt_window_hook(void (*hook)(void)) { interrupt_window_hook = hook; }
void enable_interrupts(void) { if (interrupt_window_hook) interrupt_window_hook(); }
void enable_mmu(uint64_t lowTable, uint64_t highTable) { (void)lowTable; (void)highTable; }
// Ordered record of the ordering shims, so a host suite can assert the exact
// sequence one leaf-descriptor operation emits.
//
// The count alone cannot say what these tests are about. Break-before-make is
// an *order*: the same four calls with the new descriptor published before the
// invalidation is the bug, and it has the same counts as the correct sequence.
// So each call records its position, its argument, and the value of one
// descriptor the test nominates. That last field is what makes the ordering
// observable off the machine at all: at the invalidation the descriptor has to
// read as invalid, and a suite that checks it fails on a sequence that merely
// counts right.
//
// The probe is read through a `volatile` pointer because the whole point is to
// sample memory the caller is writing between calls.
// Room for a full retirement batch of 32 pages, its stores, invalidations and
// prune, with the length still counting past it so an overflow is visible.
#define MMU_TRACE_CAPACITY 256

static uint32_t mmu_trace_ops[MMU_TRACE_CAPACITY];
static uint64_t mmu_trace_args[MMU_TRACE_CAPACITY];
static uint64_t mmu_trace_sizes[MMU_TRACE_CAPACITY];
static uint64_t mmu_trace_lines[MMU_TRACE_CAPACITY];
static uint64_t mmu_trace_descriptors[MMU_TRACE_CAPACITY];
static uint64_t mmu_trace_len;
static const uint64_t *mmu_trace_probe;

static void mmu_trace_record_range(uint32_t op, uint64_t arg, uint64_t size, uint64_t line) {
    if (mmu_trace_len < MMU_TRACE_CAPACITY) {
        mmu_trace_ops[mmu_trace_len]         = op;
        mmu_trace_args[mmu_trace_len]        = arg;
        mmu_trace_sizes[mmu_trace_len]       = size;
        mmu_trace_lines[mmu_trace_len]       = line;
        mmu_trace_descriptors[mmu_trace_len] =
            mmu_trace_probe ? *(const volatile uint64_t *)mmu_trace_probe : 0;
    }
    mmu_trace_len += 1;
}

static void mmu_trace_record(uint32_t op, uint64_t arg) {
    mmu_trace_record_range(op, arg, 0, 0);
}

// The operand a by-address invalidation hands the hardware: VA[55:12] in bits
// [43:0] and the ASID in [63:48], so a suite reads address and scope together.
static uint64_t tlbi_operand(uint64_t virtualAddress, uint16_t asid) {
    return ((virtualAddress >> 12) & ((1ULL << 44) - 1)) | ((uint64_t)asid << 48);
}

void mmu_trace_reset(const uint64_t *probe) {
    mmu_trace_len   = 0;
    mmu_trace_probe = probe;
}

uint64_t mmu_trace_length(void) { return mmu_trace_len; }

uint32_t mmu_trace_op(uint64_t index) {
    return index < MMU_TRACE_CAPACITY ? mmu_trace_ops[index] : 0;
}

uint64_t mmu_trace_arg(uint64_t index) {
    return index < MMU_TRACE_CAPACITY ? mmu_trace_args[index] : 0;
}

uint64_t mmu_trace_descriptor(uint64_t index) {
    return index < MMU_TRACE_CAPACITY ? mmu_trace_descriptors[index] : 0;
}

uint64_t mmu_trace_size(uint64_t index) {
    return index < MMU_TRACE_CAPACITY ? mmu_trace_sizes[index] : 0;
}

uint64_t mmu_trace_line(uint64_t index) {
    return index < MMU_TRACE_CAPACITY ? mmu_trace_lines[index] : 0;
}

void flush_tlb(void) { mmu_trace_record(MMU_OP_TLB_ALL, 0); }
void flush_tlb_sync(void) { mmu_trace_record(MMU_OP_TLB_SYNC, 0); }
void flush_tlb_asid(uint16_t asid) { mmu_trace_record(MMU_OP_TLB_ASID, asid); }
void flush_tlb_leaf_nosync(uint64_t virtualAddress, uint16_t asid) {
    mmu_trace_record(MMU_OP_TLB_LEAF, tlbi_operand(virtualAddress, asid));
}
void flush_tlb_table_nosync(uint64_t virtualAddress, uint16_t asid) {
    mmu_trace_record(MMU_OP_TLB_TABLE, tlbi_operand(virtualAddress, asid));
}

// CTR_EL0 as a suite stages it. Zero until set, which the kernel decodes as the
// policy that assumes the least.
static uint64_t cache_type;

void host_set_cache_type(uint64_t value) { cache_type = value; }
uint64_t read_cache_type(void) { return cache_type; }

static uint64_t main_id;
static uint64_t main_id_reads;

void host_set_main_id(uint64_t value) { main_id = value; }
uint64_t host_main_id_reads(void) { return main_id_reads; }
uint64_t read_main_id(void) {
    main_id_reads += 1;
    return main_id;
}

static uint64_t dczid;

void host_set_dczid(uint64_t value) { dczid = value; }
uint64_t read_dczid(void) { return dczid; }

void zero_blocks(void *base, uint64_t count, uint64_t block) {
    mmu_trace_record_range(MMU_OP_ZERO_BLOCKS, (uint64_t)base, count * block, block);
    memset(base, 0, count * block);
}

void clean_dcache_pou(void *base, uint64_t size, uint64_t line) {
    mmu_trace_record_range(MMU_OP_DCACHE_CLEAN_POU, (uint64_t)base, size, line);
}
void clean_dcache_poc(void *base, uint64_t size, uint64_t line) {
    mmu_trace_record_range(MMU_OP_DCACHE_CLEAN_POC, (uint64_t)base, size, line);
}
void invalidate_icache_lines(void *base, uint64_t size, uint64_t line) {
    mmu_trace_record_range(MMU_OP_ICACHE_LINES, (uint64_t)base, size, line);
}
void invalidate_icache_all(void) { mmu_trace_record(MMU_OP_ICACHE_ALL, 0); }
void synchronize_instruction_stream(void) { mmu_trace_record(MMU_OP_INSTRUCTION_STREAM, 0); }
uint64_t get_current_process(void) { return current_process; }
void instruction_barrier(void) { mmu_trace_record(MMU_OP_INSTRUCTION_BARRIER, 0); }
static uint8_t mmu_enabled;

void host_set_mmu_enabled(uint8_t value) { mmu_enabled = value; }
uint8_t is_mmu_enabled(void) { return mmu_enabled; }
void jump_to_user_mode(void *trapFrame, uint64_t rootTable, uint16_t asid) {
    (void)trapFrame; (void)rootTable; (void)asid;
}
void kernel_idle_loop(void) {}
// Reads and writes host memory on the host, which is what a suite that hands
// these a buffer of its own wants: the bounds are the behaviour under test, the
// device is not.
uint32_t mmio_read32(void *address) { return *(volatile uint32_t *)address; }
void mmio_write32(void *address, uint32_t value) { *(volatile uint32_t *)address = value; }
void nop(void) {}
void page_table_barrier(void) { barrier_count += 1; mmu_trace_record(MMU_OP_PAGE_TABLE_BARRIER, 0); }
uint64_t page_table_barrier_count(void) { return barrier_count; }
void reset_page_table_barrier_count(void) { barrier_count = 0; }

// Recorded rather than ignored. There are no caches to clean on the host, but
// whether the kernel asked, and over which bytes, is the property under test:
// a DMA buffer zeroed through a cached mapping and not pushed out again is a
// buffer a device may read as whatever was there before.
static uint64_t dcache_clean_count = 0;
static uint64_t dcache_clean_base  = 0;
static uint64_t dcache_clean_size  = 0;

void clean_dcache_range(void *base, uint64_t size) {
    dcache_clean_count += 1;
    dcache_clean_base   = (uint64_t)base;
    dcache_clean_size   = size;
}

uint64_t dcache_clean_calls(void)  { return dcache_clean_count; }
uint64_t dcache_cleaned_base(void) { return dcache_clean_base; }
uint64_t dcache_cleaned_size(void) { return dcache_clean_size; }

void reset_dcache_clean_record(void) {
    dcache_clean_count = 0;
    dcache_clean_base  = 0;
    dcache_clean_size  = 0;
}
void pl011_write_byte(void *base, uint8_t byte) { (void)base; (void)byte; }
static uint8_t (*serial_write_hook)(uint8_t);
void host_set_serial_write_hook(uint8_t (*hook)(uint8_t)) { serial_write_hook = hook; }
uint8_t pl011_try_write_byte(void *base, uint8_t byte) {
    (void)base;
    return serial_write_hook ? serial_write_hook(byte) : 1;
}
void pmu_init(void) {}
uint64_t pmu_read_cycles(void) { return 0; }
uint64_t pmu_read_event0(void) { return 0; }
uint64_t pmu_read_id_aa64dfr0(void) { return 0; }
uint64_t pmu_read_pmcr(void) { return 0; }
uint64_t pmu_read_pmceid0(void) { return 0; }
void rearm_core_timer(void) {}
// The firmware call that stops the machine. On the host there is no firmware
// and nothing to stop, so it answers "not supported" and comes back - which is
// also what the caller is written to survive.
uint64_t psci_hvc(uint64_t function, uint64_t a, uint64_t b, uint64_t c) {
    (void)function; (void)a; (void)b; (void)c;
    return (uint64_t)-1;
}

// Stateful, like `current_process`, so a suite can stage the clock a latency is
// measured against. Zero until set, which is what every other suite reads.
static uint64_t virtual_counter;
static int monotonic_counter;

void host_use_monotonic_counter(int enabled) { monotonic_counter = enabled; }

static uint64_t host_counter(void) {
    if (!monotonic_counter) return virtual_counter;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}
static uint64_t timer_deadline;
static uint64_t counter_frequency;

void host_set_virtual_counter(uint64_t value) { virtual_counter = value; }
void host_set_timer_deadline(uint64_t value) { timer_deadline = value; }
void host_set_counter_frequency(uint64_t value) { counter_frequency = value; }

uint64_t read_counter_frequency(void) { return counter_frequency; }
uint64_t read_timer_deadline(void) { return timer_deadline; }
uint64_t read_virtual_counter(void) { return host_counter(); }
uint64_t read_virtual_counter_unordered(void) { return host_counter(); }
void set_current_process(uint64_t process) { current_process = process; }
void switch_user_address_space(uint64_t rootTable, uint16_t asid) { (void)rootTable; (void)asid; }
uint64_t asid_bits(void) { return 16; }
void trigger_trap(void) {}
void wait_for_interrupt(void) {}

// Host stand-ins for the Reix userland syscall and ordering shims. The terminal
// transport tests exercise only shared-page state, but linking `Reix` brings its
// public syscall wrappers in as one module.
static void (*data_barrier_hook)(void);
void host_set_data_barrier_hook(void (*hook)(void)) { data_barrier_hook = hook; }
void dmb_ish(void) {
    barrier_count += 1;
    if (data_barrier_hook) data_barrier_hook();
}
uint64_t reix_pmu_cycles(void) { return 0; }
uint64_t reix_pmu_event0(void) { return 0; }
uint64_t _asm_syscall(uint64_t number, ...) { (void)number; return 0; }
uint64_t _asm_call(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_recv(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_recv_timeout(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_spawn(uint64_t first, ...) { (void)first; return 0; }
void kernel_host_shims_link_anchor(void) {}
