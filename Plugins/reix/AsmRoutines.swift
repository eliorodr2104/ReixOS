//
//  AsmRoutines.swift
//  ReixOS
//
//  The trivial AArch64 wrappers, expressed with the AsmDSL. Rendered to `.S`
//  by the plugin at build time. Faithful ports of the former CpuHandlers.S,
//  AArch64MMUHandlers.S and VirtualTimer.S.
//

private func cpuHandlers() -> [AsmRoutine] {
    [
        fn("disable_interrupts") { msr("daifset", 3); ret() },
        fn("enable_interrupts")  { msr("daifclr", 2); ret() },

        fn("instruction_barrier") { isb(); ret() },
        fn("wait_for_interrupt") { wfi(); ret() },
        fn("nop")                { nop(); ret() },
        fn("wait_for_exception") { wfe(); b("wait_for_exception") },
        fn("trigger_trap")       { brk(0) },
        fn("jump_to_high_half") {
            mov("x1", "sp")
            add("x1", "x1", "x0")
            mov("sp", "x1")
            add("x30", "x30", "x0")
            adr("x1", ".L_trampoline_target")
            add("x1", "x1", "x0")
            br("x1")
            label(".L_trampoline_target")
            ret()
        },
        // One 32-bit load and one 32-bit store to a device register, in
        // assembly for the reason `PL011UART` documents at length: Swift cannot
        // spell a volatile access, and over a plain pointer the optimiser is
        // free to hoist, merge or drop one. x0 is the address, x1 the value.
        fn("mmio_read32")  { raw("    ldr w0, [x0]"); ret() },
        fn("mmio_write32") { raw("    str w1, [x0]"); ret() },

        // The firmware call that turns the machine off. On this machine it is
        // reached with `hvc`, which is what the device tree's PSCI node says
        // and what QEMU's virt board provides. `smc` is the other spelling and
        // is here so a board that wants it is a one-line change rather than a
        // new routine. Neither returns when the call is SYSTEM_OFF.
        fn("psci_hvc") { raw("    hvc #0"); ret() },
        fn("psci_smc") { raw("    smc #0"); ret() },

        fn("set_vbar")             { msr("vbar_el1", "x0"); ret() },
        fn("set_current_process")  { msr("tpidr_el1", "x0"); ret() },
        fn("get_current_process")  { mrs("x0", "tpidr_el1"); ret() },

        fn("kernel_idle_loop") {
            raw("    ldr x0, =stack_top")
            raw("    ldr x1, =0xFFFF800000000000")
            add("x0", "x0", "x1")
            mov("sp", "x0")
            // IRQ only. The tick is the one thing that gets the CPU back out of
            // here, and FIQ has no handler to get it out with.
            msr("daifclr", 2)
            label(".L_idle")
            wfi()
            b(".L_idle")
        }
    ]
}

private func mmuHandlers() -> [AsmRoutine] {
    let addressSizes: UInt64 = (16 << 0)  | (16 << 16)
    let shareability: UInt64 = (3  << 12) | (3  << 28)
    let cacheability: UInt64 = (1  << 8)  | (1  << 10) | (1 << 24) | (1 << 26)
    let granuleSizes: UInt64 = (0  << 14) | (2  << 30)
    let asidSize    : UInt64 = (1  << 36)

    let tcr: UInt64 = addressSizes | shareability | cacheability | granuleSizes | asidSize

    return [
        fn("enable_mmu") {
            // MAIR attributes, one byte per index: 0 normal write-back, 1 device
            // nGnRE, 2 normal non-cacheable. The third is what a DMA buffer is
            // mapped with, and it was zero until it had a user, which spells
            // Device-nGnRnE and not the Normal NC `MairIndex` promised.
            ldrImm("x2", 0x4404FF)
            msr("mair_el1", "x2")
            ldrImm("x2", tcr)
            msr("tcr_el1", "x2")
            msr("ttbr0_el1", "x0")
            msr("ttbr1_el1", "x1")
            tlbi("vmalle1")
            ic("iallu")
            dsb("sy")
            isb()
            mrs("x2", "sctlr_el1")
            ldrImm("x3", 0x1005) // M | A | C | I
            orr("x2", "x2", "x3")
            msr("sctlr_el1", "x2")
            isb()
            ret()
        },
        fn("is_mmu_enabled") {
            mrs("x0", "sctlr_el1")
            and("x0", "x0", 1)
            ret()
        },
        fn("flush_tlb") {
            dsb("ishst")
            tlbi("vmalle1is")
            dsb("ish")
            isb()
            ret()
        },

        fn("flush_tlb_page") {
            dsb("ishst")
            raw("    lsr x0, x0, #12")
            raw("    tlbi vaae1is, x0")
            dsb("ish")
            isb()
            ret()
        },

        fn("flush_tlb_page_nosync") {
            raw("    lsr x0, x0, #12")
            raw("    tlbi vaae1is, x0")
            ret()
        },

        fn("flush_tlb_sync") {
            dsb("ish")
            isb()
            ret()
        },

        fn("page_table_barrier") {
            dsb("ishst")
            ret()
        },

        // clean_dcache_range(base, size): writes back and drops every cache line
        // covering [base, base + size), then waits for it.
        //
        // For memory the kernel wrote through its own cached mapping and a
        // device is about to read through a non-cacheable one. Two mappings with
        // different cacheability over the same bytes is a mismatched alias, and
        // the architecture says nothing about which of them wins: the write may
        // still be sitting in a cache the device cannot see, and worse, that line
        // may be written out later and land on top of what the device or the
        // driver put there since.
        //
        // `civac` and not `cvac`: cleaning alone would leave the line valid, and
        // a stale valid line over memory only a device writes is the same bug
        // pointing the other way.
        //
        // The line size comes from CTR_EL0 rather than a constant, because a
        // constant that is too large skips lines. `dsb sy` and not `ish`: the
        // observer that has to see this is a device.
        fn("clean_dcache_range") {
            raw("    cbz x1, .L_dcache_done")
            mrs("x2", "ctr_el0")
            raw("    ubfx x2, x2, #16, #4")
            mov("x3", 4)
            raw("    lsl x3, x3, x2")
            add("x1", "x0", "x1")
            raw("    sub x2, x3, #1")
            raw("    bic x0, x0, x2")
            label(".L_dcache_loop")
            raw("    dc civac, x0")
            add("x0", "x0", "x3")
            raw("    cmp x0, x1")
            raw("    b.lo .L_dcache_loop")
            label(".L_dcache_done")
            dsb("sy")
            ret()
        },

        fn("switch_user_address_space") {
            raw("    bfi x0, x1, #48, #16")
            msr("ttbr0_el1", "x0")
            isb()
            ret()
        },
    ]
}

private func virtualTimer() -> [AsmRoutine] {
    // Scheduler tick rate, the one place it is written.
    let tickHz = 100

    return [
        // Per-core, once at bring-up: derive this core's interval, arm the first
        // deadline from the counter and enable the core's own timer.
        fn("enable_core_timer") {
            mrs("x1", "cntfrq_el0")
            mov("x2", tickHz)
            udiv("x1", "x1", "x2")

            mrs("x2", "cntvct_el0")
            add("x2", "x2", "x1")
            msr("cntv_cval_el0", "x2")

            mov("x2", 1)
            msr("cntv_ctl_el0", "x2")
            ret()
        },

        // Per-tick: push the deadline one interval on. Both routines recompute
        // the interval, so neither depends on state some other core wrote.
        fn("rearm_core_timer") {
            mrs("x1", "cntfrq_el0")
            mov("x2", tickHz)
            udiv("x1", "x1", "x2")

            mrs("x2", "cntv_cval_el0")
            add("x2", "x2", "x1")

            // A deadline already behind the counter means the tick was serviced
            // late: rearm from now, or the timer fires again immediately.
            mrs("x3", "cntvct_el0")
            raw("    cmp  x2, x3")
            add("x3", "x3", "x1")
            raw("    csel x2, x2, x3, hi")

            msr("cntv_cval_el0", "x2")
            ret()
        },

        // The only clock Swift can read. `RoundRobin.systemTicks` has 10 ms
        // granularity; the virtual counter ~16 ns (~62.5 MHz on QEMU virt).
        fn("read_virtual_counter") {
            // `isb` first, or CNTVCT_EL0 reads get speculated ahead of the work
            // being timed and two stamps around a short region come back reordered.
            isb()
            mrs("x0", "cntvct_el0")
            ret()
        },

        // The same read without the barrier, for a stamp nobody subtracts from
        // another: a log line does not care about a few cycles of skew.
        fn("read_virtual_counter_unordered") {
            mrs("x0", "cntvct_el0")
            ret()
        },

        // Ticks per second, so a counter delta can be turned into a duration.
        fn("read_counter_frequency") {
            mrs("x0", "cntfrq_el0")
            ret()
        },
    ]
}

/// PMUv3: the cycle counter and one programmable event counter.
///
/// Every one of these is a system-register access Swift has no spelling for, so
/// they are here for the same reason the timer reads are, and not because the
/// bodies are interesting. See Kernel `AArch64PMU`.
private func performanceMonitors() -> [AsmRoutine] {
    // PMCNTENSET_EL0 bit 31 is the cycle counter, bit 0 event counter 0.
    let countersEnabled: UInt64 = (1 << 31) | (1 << 0)

    return [
        fn("pmu_read_id_aa64dfr0") {
            mrs("x0", "id_aa64dfr0_el1")
            ret()
        },

        fn("pmu_init") {
            // PMCR_EL0 E | P | C: switch the block on and zero both the event
            // counters and the cycle counter, so the first read starts at boot.
            mov("x0", 0b111)
            msr("pmcr_el0", "x0")

            ldrImm("x1", countersEnabled)
            msr("pmcntenset_el0", "x1")

            // Event counter 0 counts INST_RETIRED (0x08). Selected through
            // PMSELR_EL0, whose write must be synchronized before the type lands.
            msr("pmselr_el0", "xzr")
            isb()
            mov("x2", 0x08)
            msr("pmxevtyper_el0", "x2")

            // PMUSERENR_EL0 CR | ER: EL0 reads the counters directly, without EN,
            // so it cannot also write PMCR_EL0 or reprogram the counters.
            mov("x3", 0b1100)
            msr("pmuserenr_el0", "x3")

            isb()
            ret()
        },

        // PMCR_EL0 itself, for the implemented-counter count in bits 15:11.
        fn("pmu_read_pmcr") {
            mrs("x0", "pmcr_el0")
            ret()
        },

        // The 64-bit cycle counter, PMCCNTR_EL0.
        fn("pmu_read_cycles") {
            // `isb` first, for `read_virtual_counter`'s reason: without it the
            // two reads bracketing a section are free to drift out of it.
            isb()
            mrs("x0", "pmccntr_el0")
            ret()
        },

        // Event counter 0, reached by selecting it and reading the window register.
        fn("pmu_read_event0") {
            msr("pmselr_el0", "xzr")
            isb()
            mrs("x0", "pmxevcntr_el0")
            ret()
        },
    ]
}

/// The kernel UART's transmit wait, in assembly for the reason userland's is.
///
/// A PL011 driver has to poll `FR.TXFF` before every store to `DR`, and that
/// poll is a volatile read Swift cannot express: LLVM treats the load as
/// loop-invariant, hoists it out and then deletes the wait, so bytes go into a
/// FIFO with no check that there is room. The kernel's Swift loop did survive,
/// but only on two opaque `bl`s that happened to land in its body,
/// `is_mmu_enabled` from recomputing the address and `nop` as the pause, and
/// removing either of those looks like a cleanup rather than a regression.
private func serialHandlers() -> [AsmRoutine] {
    [
        // PL011 transmit: poll FR.TXFF (0x18, bit 5), then store to DR (0x00).
        // x0 base, w1 byte. See Kernel `PL011UART.write(_:)`.
        fn("pl011_write_byte") {
            label(".L_pl011_byte_wait")
            raw("    ldr  w2, [x0, #0x18]")
            raw("    tbnz w2, #5, .L_pl011_byte_wait")
            raw("    strb w1, [x0]")
            ret()
        },
        fn("pl011_try_write_byte") {
            raw("    ldr  w2, [x0, #0x18]")
            raw("    tbnz w2, #5, .L_pl011_byte_full")
            raw("    strb w1, [x0]")
            mov("w0", 1)
            ret()
            label(".L_pl011_byte_full")
            mov("w0", 0)
            ret()
        },
    ]
}

/// The generated kernel assembly files (filename, rendered source).
func generatedKernelAsm() -> [(name: String, source: String)] {
    [
        ("CpuHandlers.gen.S",        renderAsmFile(cpuHandlers())),
        ("AArch64MMUHandlers.gen.S", renderAsmFile(mmuHandlers())),
        ("VirtualTimer.gen.S",       renderAsmFile(virtualTimer())),
        ("AArch64PMU.gen.S",         renderAsmFile(performanceMonitors())),
        ("PL011UART.gen.S",          renderAsmFile(serialHandlers())),
    ]
}


// MARK: - Userland

/// Trivial wrappers linked into every userland ELF (alongside Native/reix).
private func reixRoutines() -> [AsmRoutine] {
    [
        // Inner-shareable memory barrier: orders the SPSC ring's data vs index
        // accesses (release on push, acquire on pop). See Reix `dmbISH()`.
        fn("dmb_ish") { dmb("ish"); ret() },

        // The two halves of handing memory to a device and taking it back.
        //
        // Outer shareable, not inner, and that is the whole reason these are not
        // `dmb_ish`: the other observer is not a CPU in this core's inner domain,
        // it is a device. The DMA mapping is Normal Non-Cacheable, which buys
        // visibility without maintenance and says nothing whatever about
        // ordering, so ordering is these. Linux draws the same line and spells
        // it the same way: `dma_wmb()` is `dmb oshst`, `dma_rmb()` is `dmb oshld`.
        //
        // Store-only and load-only rather than full barriers, because that is
        // what each side needs: descriptors before the index that publishes them,
        // and the index that reports a completion before anything written under
        // it. See Reix `dmaWriteBarrier()` and `dmaReadBarrier()`.
        fn("dma_write_barrier") { dmb("oshst"); ret() },
        fn("dma_read_barrier")  { dmb("oshld"); ret() },

        // PL011 transmit: poll FR.TXFF (0x18, bit 5) before every store to DR
        // (0x00). x0 base, x1 bytes, x2 count. See Reix `pl011WriteSpan()`.
        fn("pl011_write_span") {
            raw("    cmp  x2, #0")
            raw("    b.le .L_pl011_span_done")
            label(".L_pl011_span_byte")
            raw("    ldrb w3, [x1], #1")
            label(".L_pl011_span_wait")
            raw("    ldr  w4, [x0, #0x18]")
            raw("    tbnz w4, #5, .L_pl011_span_wait")
            raw("    strb w3, [x0]")
            raw("    subs x2, x2, #1")
            raw("    b.ne .L_pl011_span_byte")
            label(".L_pl011_span_done")
            ret()
        },

        // The bounded SerialServer transfer core owns one byte at a time. This
        // is the single-byte form of the span routine, linked into userland so
        // TX progress does not depend on a QEMU PL011 TX interrupt.
        fn("pl011_write_byte") {
            label(".L_user_pl011_byte_wait")
            raw("    ldr  w2, [x0, #0x18]")
            raw("    tbnz w2, #5, .L_user_pl011_byte_wait")
            raw("    strb w1, [x0]")
            ret()
        },

        // PL011 receive: one byte if the FIFO has one. Answers 0x100 when it is
        // empty, which no byte can be, so a caller needs no second call to ask.
        // x0 base. FR is 0x18 and RXFE its bit 4; DR is 0x00.
        fn("pl011_try_read_byte") {
            raw("    ldr  w1, [x0, #0x18]")
            raw("    tbnz w1, #4, .L_pl011_rx_empty")
            raw("    ldr  w0, [x0]")
            raw("    and  w0, w0, #0xff")
            ret()
            label(".L_pl011_rx_empty")
            raw("    mov  w0, #0x100")
            ret()
        },

        // One nonblocking transmit attempt. FR.TXFF is bit 5 and a false answer
        // keeps ownership with the caller without a volatile Swift load.
        fn("pl011_try_write_byte") {
            raw("    ldr  w2, [x0, #0x18]")
            raw("    tbnz w2, #5, .L_pl011_tx_full")
            raw("    strb w1, [x0]")
            raw("    mov  w0, #1")
            ret()
            label(".L_pl011_tx_full")
            raw("    mov  w0, #0")
            ret()
        },

        // Arm the receive interrupts in the device itself: IMSC (0x38) bit 4 is
        // a full FIFO, bit 6 a partial one that stopped filling, and a terminal
        // needs the second or a lone keystroke would wait for a full buffer.
        // Any stale condition is cleared first through ICR (0x44).
        fn("pl011_enable_receive") {
            raw("    mov  w1, #0x7ff")
            raw("    str  w1, [x0, #0x44]")
            raw("    ldr  w1, [x0, #0x38]")
            // Through a register: 0x50 is not one of the repeating bit patterns
            // a logical immediate can encode.
            raw("    mov  w2, #0x50")
            raw("    orr  w1, w1, w2")
            raw("    str  w1, [x0, #0x38]")
            ret()
        },

        // Acknowledge at the device what was just drained, which has to happen
        // before the line is unmasked at the controller or it fires again on
        // the same condition.
        fn("pl011_clear_receive") {
            raw("    mov  w1, #0x50")
            raw("    str  w1, [x0, #0x44]")
            ret()
        },

        // TX is independent from RX: a full transmit FIFO must not disable
        // receive delivery while the server waits for room.
        fn("pl011_enable_transmit_interrupt") {
            raw("    ldr  w1, [x0, #0x38]")
            raw("    orr  w1, w1, #0x20")
            raw("    str  w1, [x0, #0x38]")
            ret()
        },

        fn("pl011_disable_transmit_interrupt") {
            raw("    ldr  w1, [x0, #0x38]")
            raw("    bic  w1, w1, #0x20")
            raw("    str  w1, [x0, #0x38]")
            ret()
        },

        fn("pl011_clear_transmit_interrupt") {
            raw("    mov  w1, #0x20")
            raw("    str  w1, [x0, #0x44]")
            ret()
        },

        // The virtual counter, readable at EL0 because boot.S sets
        // CNTKCTL_EL1.EL0VCTEN. See Reix `readVirtualCounter()`.
        fn("read_virtual_counter") {
            // `isb` first, or the read gets speculated ahead of the work being
            // timed and two stamps around a short region come back reordered.
            isb()
            mrs("x0", "cntvct_el0")
            ret()
        },

        // Ticks per second, so a counter delta becomes a duration. Readable at
        // EL0 through CNTKCTL_EL1.EL0PCTEN, set alongside EL0VCTEN.
        fn("read_counter_frequency") {
            mrs("x0", "cntfrq_el0")
            ret()
        },

        // The cycle counter, readable at EL0 because `pmu_init` sets
        // PMUSERENR_EL0.CR. See Reix `PMUSection`.
        fn("reix_pmu_cycles") {
            // `isb` first, or the two reads bracketing a section are free to be
            // speculated out of it and the delta is a fiction.
            isb()
            mrs("x0", "pmccntr_el0")
            ret()
        },

        // Event counter 0, INST_RETIRED as the kernel programmed it. Readable
        // at EL0 through PMUSERENR_EL0.ER, set alongside CR.
        fn("reix_pmu_event0") {
            msr("pmselr_el0", "xzr")
            isb()
            mrs("x0", "pmxevcntr_el0")
            ret()
        },
    ]
}

/// The generated userland assembly files (filename, rendered source).
func generatedUserlandAsm() -> [(name: String, source: String)] {
    [
        ("ReixAsm.gen.S", renderAsmFile(reixRoutines())),
    ]
}
