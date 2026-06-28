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
    ]
}

private func mmuHandlers() -> [AsmRoutine] {
    let tcr: UInt64 = (16 << 0) | (16 << 16) | (3 << 12) | (3 << 28)
                    | (1 << 8)  | (1 << 10)  | (1 << 24) | (1 << 26)
                    | (0 << 14) | (2 << 30)

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
        fn("switch_user_address_space") {
            msr("ttbr0_el1", "x0")
            tlbi("vmalle1is")
            dsb("ish")
            isb()
            ret()
        },
    ]
}

private func virtualTimer() -> [AsmRoutine] {
    [
        fn("enable_core_timer") {
            mrs("x0", "cntfrq_el0")
            mov("x1", 100)
            udiv("x0", "x0", "x1")
            msr("cntv_tval_el0", "x0")
            mov("x0", 1)
            msr("cntv_ctl_el0", "x0")
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
    ]
}
