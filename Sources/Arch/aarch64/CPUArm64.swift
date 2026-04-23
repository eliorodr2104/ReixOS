//
//  CPU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct CPUArm64 {
    public static var internalKernelPanicMessage: String?
    
    @_silgen_name("nop")
    public static func nop()
    
    @_silgen_name("wait_for_exception")
    public static func waitForException()
    
    @_silgen_name("enable_interrupts")
    public static func enableInterrupts()
    
    @_silgen_name("disable_interrupts")
    public static func disableInterrupts()
    
    @_silgen_name("wait_for_interrupt")
    public static func waitForInterrupt()
    
    @_silgen_name("trigger_trap")
    public static func triggerTrap()
    
    public static func panic(
        _   reason      : String?    = nil,
        exc exception   : Exception? = nil,
        fp  framePointer: TrapFrame? = nil
    ) -> Never {
        // Disable Interrups because,
        // you stop all another corrupted instruction
        disableInterrupts()
        
        // Header Print Error
        kprint()
        kprint("=========================================================")
        kprint("=\tRaix Panic - Fatal exception in interrupt\t=")
        kprint("=========================================================")
        
        kprint()
        if let str = reason {
            kprint("Reason:")
            kprintf("\t"); kprint(str)
            kprint()
            kprint("------------------------------------------------------")
        }
        kprint()
        
        kprint("Status Post-Mortem:")
        kprint("\tPID : ######") // TODO: Not yet implemented
        kprint("\tCore: #")      // TODO: Not yet implemented
        kprint()
        kprint("------------------------------------------------------")
        
        
        if let frame = framePointer, let exc = exception {
            kprint()
            kprint("Special Registers:")
            kprintf("\tException Link Reg (PC) : 0x%x\n", frame.elr)
            kprintf("\tFault Address      (FAR): 0x%x\n", frame.far)
            kprintf("\tSyndrome           (ESR): 0x%x (Exception Class: 0x%x - ", frame.esr, exc.rawValue)
            kprint("BRK instruction)")
            kprint()
            kprint("------------------------------------------------------")

            
            kprint()
            kprint("Registers:")
            kprintf("\tx0  : 0x%x\n", frame.x0)
            kprintf("\tx1  : 0x%x\n", frame.x1)
            kprintf("\tx2  : 0x%x\n", frame.x2)
            kprintf("\tx3  : 0x%x\n", frame.x3)
            kprintf("\tx4  : 0x%x\n", frame.x4)
            kprintf("\tx5  : 0x%x\n", frame.x5)
            kprintf("\tx6  : 0x%x\n", frame.x6)
            kprintf("\tx7  : 0x%x\n", frame.x7)
            kprintf("\tx8  : 0x%x\n", frame.x8)
            kprintf("\tx9  : 0x%x\n", frame.x9)
            kprintf("\tx10 : 0x%x\n", frame.x10)
            
            kprintf("\tx11 : 0x%x\n", frame.x11)
            kprintf("\tx12 : 0x%x\n", frame.x12)
            kprintf("\tx13 : 0x%x\n", frame.x13)
            kprintf("\tx14 : 0x%x\n", frame.x14)
            kprintf("\tx15 : 0x%x\n", frame.x15)
            kprintf("\tx16 : 0x%x\n", frame.x16)
            kprintf("\tx17 : 0x%x\n", frame.x17)
            kprintf("\tx18 : 0x%x\n", frame.x18)
            kprintf("\tx19 : 0x%x\n", frame.x19)
            kprintf("\tx20 : 0x%x\n", frame.x20)
            kprintf("\tx21 : 0x%x\n", frame.x21)
            
            kprintf("\tx21 : 0x%x\n", frame.x22)
            kprintf("\tx22 : 0x%x\n", frame.x23)
            kprintf("\tx23 : 0x%x\n", frame.x24)
            kprintf("\tx24 : 0x%x\n", frame.x25)
            kprintf("\tx25 : 0x%x\n", frame.x26)
            
            kprintf("\tx27 : 0x%x\n", frame.x27)
            kprintf("\tx28 : 0x%x\n", frame.x28)
            kprintf("\tx29 : 0x%x\n", frame.x29)
            kprintf("\tx30 : 0x%x\n", frame.x30)
        }
        
        kprint("============================================")
        kprint()
                
        while true { waitForInterrupt() }
    }
}
