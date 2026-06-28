//
//  CPU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

/// AArch64CPU, CPU Abstraction for ARM Architecture.
/// Contains the most common Low-Level ASM calls.
public struct AArch64CPU: CPUInterface {


    @_silgen_name("nop")
    private static func nop_asm()

    @_silgen_name("wait_for_exception")
    public static func waitForException()

    @_silgen_name("enable_interrupts")
    private static func enable_interrupts()

    @_silgen_name("disable_interrupts")
    private static func disable_interrupts()

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


    // MARK: - Function used on protocol CPUInterface

    public static func enableInterrupts () { enable_interrupts () }
    public static func disableInterrupts() { disable_interrupts() }
    public static func triggerTrap      () { trigger_trap      () }
    public static func nop              () { nop_asm           () }

    
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


    /// Walk the saved frame-pointer chain and print every return
    /// address. Public to the rest of the kernel so the panic formatter
    /// can invoke it without exposing the unwinder publicly.
    @inline(__always)
    static func printStackTrace(_ framePointerAddress: UInt64) {
        guard framePointerAddress != 0 else { return }

        var fp = framePointerAddress
        while fp != 0 {
            let returnAddress = UnsafePointer<UInt64>(
                bitPattern: UInt(fp + 8)
            )?.pointee ?? 0

            let previousFP = UnsafePointer<UInt64>(
                bitPattern: UInt(fp)
            )?.pointee ?? 0

            if returnAddress == 0 { break }

            kprint("  [<0x\(hex: returnAddress)>]")
            fp = previousFP
        }
    }
}
