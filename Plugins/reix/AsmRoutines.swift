//
//  AsmRoutines.swift
//  ReixOS — reix plugin
//
//  The trivial AArch64 wrappers, expressed with the AsmDSL. Rendered to `.S`
//  by the plugin at build time. Faithful ports of the former CpuHandlers.S,
//  AArch64MMUHandlers.S and VirtualTimer.S.
//

private func cpuHandlers() -> [AsmRoutine] {
    [
        fn("disable_interrupts") { msr("daifset", 3); ret() },
        fn("enable_interrupts")  { msr("daifclr", 3); ret() },
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
        fn("set_vbar")             { msr("vbar_el1", "x0"); ret() },
        fn("set_current_process")  { msr("tpidr_el1", "x0"); ret() },
        fn("get_current_process")  { mrs("x0", "tpidr_el1"); ret() },

        fn("kernel_idle_loop") {
            raw("    ldr x0, =stack_top")
            raw("    ldr x1, =0xFFFF800000000000")
            add("x0", "x0", "x1")
            mov("sp", "x0")  
            msr("daifclr", 3)
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
            ldrImm("x2", 0x4FF)
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
        
        fn("switch_user_address_space") {
            raw("    bfi x0, x1, #48, #16")
            msr("ttbr0_el1", "x0")
            isb()
            ret()
        },
    ]
}

private func virtualTimer() -> [AsmRoutine] {
    [
        fn("enable_core_timer") {
            raw("    adrp x1, timer_tick_interval")
            raw("    add  x1, x1, :lo12:timer_tick_interval")
            raw("    ldr  x2, [x1]")
            raw("    cbz  x2, .L_timer_first_enable")

            mrs("x3", "cntv_cval_el0")
            add("x3", "x3", "x2")
            mrs("x4", "cntvct_el0")
            raw("    cmp  x3, x4")
            add("x4", "x4", "x2")
            raw("    csel x3, x3, x4, hi")
            msr("cntv_cval_el0", "x3")
            ret()

            label(".L_timer_first_enable")
            mrs("x2", "cntfrq_el0")
            mov("x3", 100)
            udiv("x2", "x2", "x3")
            raw("    str  x2, [x1]")

            mrs("x3", "cntvct_el0")
            add("x3", "x3", "x2")
            msr("cntv_cval_el0", "x3")
            mov("x3", 1)
            msr("cntv_ctl_el0", "x3")
            ret()

            raw(".section .data")
            raw("    .align 3")
            raw("timer_tick_interval:")
            raw("    .quad 0")
            raw(".section .text")
        },
    ]
}

/// The generated kernel assembly files (filename, rendered source).
func generatedKernelAsm() -> [(name: String, source: String)] {
    [
        ("CpuHandlers.gen.S",        renderAsmFile(cpuHandlers())),
        ("AArch64MMUHandlers.gen.S", renderAsmFile(mmuHandlers())),
        ("VirtualTimer.gen.S",       renderAsmFile(virtualTimer())),
    ]
}


// MARK: - Userland

/// Trivial wrappers linked into every userland ELF (alongside Native/reix).
private func reixRoutines() -> [AsmRoutine] {
    [
        // Inner-shareable memory barrier — orders the SPSC ring's data vs index
        // accesses (release on push, acquire on pop). See Reix `dmbISH()`.
        fn("dmb_ish") { dmb("ish"); ret() },
    ]
}

/// The generated userland assembly files (filename, rendered source).
func generatedUserlandAsm() -> [(name: String, source: String)] {
    [
        ("ReixAsm.gen.S", renderAsmFile(reixRoutines())),
    ]
}
