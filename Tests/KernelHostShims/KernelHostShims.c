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
void pl011_write_byte(void *base, uint8_t byte) { (void)base; (void)byte; }
uint8_t pl011_try_write_byte(void *base, uint8_t byte) { (void)base; (void)byte; return 1; }
void pmu_init(void) {}
uint64_t pmu_read_cycles(void) { return 0; }
uint64_t pmu_read_event0(void) { return 0; }
uint64_t pmu_read_id_aa64dfr0(void) { return 0; }
uint64_t pmu_read_pmcr(void) { return 0; }
void rearm_core_timer(void) {}
uint64_t read_counter_frequency(void) { return 0; }
uint64_t read_virtual_counter(void) { return 0; }
uint64_t read_virtual_counter_unordered(void) { return 0; }
void set_current_process(uint64_t process) { current_process = process; }
void switch_user_address_space(uint64_t rootTable, uint16_t asid) { (void)rootTable; (void)asid; }
void trigger_trap(void) {}
void wait_for_interrupt(void) {}
