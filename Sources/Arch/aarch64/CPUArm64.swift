//
//  CPU.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//

public struct CPUArm64 {
    
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
    
    public static func panic(_ reason: String) -> Never {
        disableInterrupts()
        
        kprint("!!! KERNEL PANIC !!!")
        kprint(reason)
        
        while true { waitForInterrupt() }
    }
}
