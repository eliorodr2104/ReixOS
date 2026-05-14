//
//  CPU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

/// AArch64CPU, CPU Abstraction for ARM Architecture.
/// Contains the most common Low-Level ASM calls
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
    public static func getCurrentProcess() -> VirtualAddress
    
    
    // MARK: - Function used on protocol CPUInterface
    
    public static func enableInterrupts() {
        enable_interrupts()
    }
    
    public static func disableInterrupts() {
        disable_interrupts()
    }
    
    public static func triggerTrap() {
        trigger_trap()
    }
    
    public static func nop() {
        nop_asm()
    }
    
    
    /// Turn of the system.
    ///
    /// Disable the interrupts, print register satte and the backtrace,
    /// set core to sleep mode, using a WFI procedure.
    ///
    /// - Parameters:
    ///     - reason: String for describe the error.
    ///     - exception: Enum exception, this is captured on kernel error.
    ///     - framePointer: Pointer to TrapFrame, contains state of registers when kernel is crashing.
    @inline(__always) // TODO: Considering leave inlinable func, because the Stack on boot is small
    public static func panic(
        _   reason      : String?         = nil,
        exc exception   : Exception?      = nil,
        fp  framePointer: Arch.TrapFrame? = nil
    ) -> Never {
        
        // Disable Interrupts because in Panic mode the CPU
        // Is blocked
        disableInterrupts()
        
        kprint()
        kprint("[PANIC] CPU 0 - Fatal Exception at EL1")
        kprint("------------------------------------------------------")
        
        if let frame = framePointer, let exc = exception {
            kprintf("Trap Type: Exception Class 0x%x (ESR: 0x%x)\n", exc.rawValue, frame.esr)
        }
        
        if let str = reason {
            kprint("Reason:    "); kprint(str)
        }
        
        if let frame = framePointer {
            kprintf("Address:   PC [0x%x] | FAR [0x%x]\n", frame.elr, frame.far)
            kprintf("Context:   PID: ###### | Core: 0 | PSTATE: 0x%x\n", frame.spsr)
        } else {
            kprint("Context:   PID: ###### | Core: 0")
        }
        
        kprint("------------------------------------------------------")
        
        // Current FP state
        if let frame = framePointer {
            kprint()
            kprint("GPR State:")
            kprintf(" x0-x3  : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x0, frame.x1, frame.x2, frame.x3)
            kprintf(" x4-x7  : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x4, frame.x5, frame.x6, frame.x7)
            kprintf(" x8-x11 : 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x8, frame.x9, frame.x10, frame.x11)
            kprintf(" x12-x15: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x12, frame.x13, frame.x14, frame.x15)
            kprintf(" x16-x19: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x16, frame.x17, frame.x18, frame.x19)
            kprintf(" x20-x23: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x20, frame.x21, frame.x22, frame.x23)
            kprintf(" x24-x27: 0x%x - 0x%x - 0x%x - 0x%x\n", frame.x24, frame.x25, frame.x26, frame.x27)
            kprintf(" x28-x29: 0x%x - 0x%x\n", frame.x28, frame.x29)
            kprintf(" lr(x30): 0x%x\n", frame.x30)
            
            kprint()
            kprint("Call Trace:")

            kprintf("  [<0x%x>] (PC/ELR)\n", frame.elr)
            kprintf("  [<0x%x>] (LR/x30)\n", frame.x30)
            
            printStackTrace(frame.x29)
        }
        
        kprint("------------------------------------------------------")
        kprint("=                SYSTEM HALTED                       =")
        kprint("------------------------------------------------------")
        
        // Block CPU and not consuming energy
        while true { waitForInterrupt() }
    }
    
    /// Print current register state of current frame pointer
    /// - Parameters:
    ///     - framePointerAddress: Address of FramePointer struct on the memory
    @inline(__always)
    private static func printStackTrace(_ framePointerAddress: UInt64) {
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
            
            kprintf("  [<0x%x>]\n", returnAddress)
            fp = previousFP
        }
    }
}
