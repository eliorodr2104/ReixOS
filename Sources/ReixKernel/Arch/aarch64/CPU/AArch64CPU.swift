//
//  CPU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

/// AArch64CPU, CPU Abstraction for ARM Architecture.
/// Contains the most common Low-Level ASM calls.
public struct AArch64CPU: CPUInterface {


    /// One `nop` instruction, and nothing else: not a barrier, not a fence,
    /// and no ordering guarantee of any kind.
    ///
    /// It has no caller left in the tree. It used to be the pause in
    /// `PL011UART`'s transmit wait, where it was one of the two opaque calls
    /// that happened to keep the FIFO-full load inside the loop, so a `nop`
    /// was quietly holding up the flow control of the whole log. That wait is
    /// `pl011_write_byte` now, in assembly. Nothing may go back to leaning on
    /// this to hold a volatile access in place: the guarantee was never in the
    /// instruction, only in the call boundary that happened to surround it.
    @_silgen_name("nop")
    private static func nop_asm()

    @_silgen_name("wait_for_exception")
    public static func waitForException()

    @_silgen_name("enable_interrupts")
    private static func enable_interrupts()

    @_silgen_name("disable_interrupts")
    private static func disable_interrupts()

    @_silgen_name("instruction_barrier")
    private static func instruction_barrier()

    @_silgen_name("wait_for_interrupt")
    public static func waitForInterrupt()

    @_silgen_name("trigger_trap")
    private static func trigger_trap()

    @_silgen_name("set_vbar")
    public static func setVBAR(_ address: VirtualAddress)

    @_silgen_name("set_current_process")
    public static func setCurrentProcess(_ address: VirtualAddress)

    @_silgen_name("get_current_process")
    public static func getCurrentProcessRaw() -> VirtualAddress
    
    @_silgen_name("kernel_idle_loop")
    public static func idleLoop() -> Never


    // MARK: - Function used on protocol CPUInterface

    public static func enableInterrupts()  { enable_interrupts () }
    public static func disableInterrupts() { disable_interrupts() }

    /// Waits for every instruction before it to be seen, so a system-register
    /// write takes effect before what follows depends on it.
    ///
    /// Needed because writing `DAIF` is not context-synchronizing: an unmask
    /// and a remask a few instructions apart are free to be observed as one
    /// no-op, and the interrupt window between them never opens.
    public static func instructionBarrier() { instruction_barrier() }
    public static func triggerTrap()        { trigger_trap()        }
    public static func nop()                { nop_asm()             }

    
    public static func getCurrentProcess() -> UnsafeMutablePointer<Process>? {
        let processAddress = Self.getCurrentProcessRaw()
 
        return UnsafeMutablePointer<Process>(bitPattern: UInt(processAddress))
    }
    

    /// Drive the kernel into a controlled halt.
    ///
    /// Thin orchestrator over the three POP-shaped components in the
    /// `Diagnostics/Panic` folder: gathers the live state into a
    /// `PanicReport`, hands it to `DefaultPanicFormatter` for rendering
    /// and then defers to `HaltPanicAction` for the terminal step.
    /// Alternative formatters/actions can be plugged through the
    /// dedicated `panic(report:formattedBy:finishedBy:)` overload.
    @inline(__always)
    public static func panic(
        _   reason   : StaticString?   = nil,
        exc exception: Exception?      = nil,
        fp  frame    : Arch.TrapFrame? = nil
    ) -> Never {

        disableInterrupts()

        let report = PanicReport(
            reason   : reason,
            exception: exception,
            frame    : frame
        )

        DefaultPanicFormatter.format(report)
        HaltPanicAction.execute()
    }


    /// Pluggable variant of `panic` used by code paths that want to
    /// override the rendering or the terminal action while keeping the
    /// data-collection invariants.
    @inline(__always)
    public static func panic<F: PanicFormatter, A: PanicAction>(
        report      : PanicReport,
        formattedBy : F.Type,
        finishedBy  : A.Type
    ) -> Never {

        disableInterrupts()

        F.format(report)
        A.execute()
    }
}
