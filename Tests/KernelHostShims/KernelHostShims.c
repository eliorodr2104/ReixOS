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
void enable_interrupts(void) {}
void enable_mmu(uint64_t lowTable, uint64_t highTable) { (void)lowTable; (void)highTable; }
void flush_tlb(void) {}
void flush_tlb_page(uint64_t virtualAddress) { (void)virtualAddress; }
void flush_tlb_page_nosync(uint64_t virtualAddress) { (void)virtualAddress; }
void flush_tlb_sync(void) {}
uint64_t get_current_process(void) { return current_process; }
void instruction_barrier(void) {}
uint8_t is_mmu_enabled(void) { return 0; }
void jump_to_user_mode(void *trapFrame, uint64_t rootTable) { (void)trapFrame; (void)rootTable; }
void kernel_idle_loop(void) {}
// Reads and writes host memory on the host, which is what a suite that hands
// these a buffer of its own wants: the bounds are the behaviour under test, the
// device is not.
uint32_t mmio_read32(void *address) { return *(volatile uint32_t *)address; }
void mmio_write32(void *address, uint32_t value) { *(volatile uint32_t *)address = value; }
void nop(void) {}
void page_table_barrier(void) { barrier_count += 1; }
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
uint8_t pl011_try_write_byte(void *base, uint8_t byte) { (void)base; (void)byte; return 1; }
void pmu_init(void) {}
uint64_t pmu_read_cycles(void) { return 0; }
uint64_t pmu_read_event0(void) { return 0; }
uint64_t pmu_read_id_aa64dfr0(void) { return 0; }
uint64_t pmu_read_pmcr(void) { return 0; }
void rearm_core_timer(void) {}
// The firmware call that stops the machine. On the host there is no firmware
// and nothing to stop, so it answers "not supported" and comes back - which is
// also what the caller is written to survive.
uint64_t psci_hvc(uint64_t function, uint64_t a, uint64_t b, uint64_t c) {
    (void)function; (void)a; (void)b; (void)c;
    return (uint64_t)-1;
}

uint64_t read_counter_frequency(void) { return 0; }
uint64_t read_virtual_counter(void) { return 0; }
uint64_t read_virtual_counter_unordered(void) { return 0; }
void set_current_process(uint64_t process) { current_process = process; }
void switch_user_address_space(uint64_t rootTable, uint16_t asid) { (void)rootTable; (void)asid; }
void trigger_trap(void) {}
void wait_for_interrupt(void) {}

// Host stand-ins for the Reix userland syscall and ordering shims. The terminal
// transport tests exercise only shared-page state, but linking `Reix` brings its
// public syscall wrappers in as one module.
void dmb_ish(void) { barrier_count += 1; }
uint64_t reix_pmu_cycles(void) { return 0; }
uint64_t reix_pmu_event0(void) { return 0; }
uint64_t _asm_syscall(uint64_t number, ...) { (void)number; return 0; }
uint64_t _asm_call(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_recv(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_recv_timeout(uint64_t handle, ...) { (void)handle; return 0; }
uint64_t _asm_spawn(uint64_t first, ...) { (void)first; return 0; }
void kernel_host_shims_link_anchor(void) {}
