//
//  TrapFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


/// Represents the CPU execution context saved during an exception or interrupt.
///
/// This structure captures the full state of the General Purpose Registers (GPRs)
/// and critical System Registers at the moment a trap occurs.
///
/// - Important: The memory layout of this struct must exactly match the order in
/// which registers are pushed onto the stack by the assembly exception vector code.
@frozen
public struct AArch64TrapFrame {
        
    /// Registers x0 through x7 (typically used for parameter passing and return values).
    public var x0,  x1,  x2,  x3,  x4,  x5,  x6,  x7 : UInt64
    
    /// Registers x8 through x15.
    public var x8,  x9,  x10, x11, x12, x13, x14, x15: UInt64
    
    /// Registers x16 through x23.
    public var x16, x17, x18, x19, x20, x21, x22, x23: UInt64
    
    /// Registers x24 through x28.
    public var x24, x25, x26, x27, x28: UInt64
    
    /// Frame Pointer (x29). Used for stack unwinding.
    public var x29: UInt64
    
    /// Link Register (x30). Holds the return address for function calls.
    public var x30: UInt64
    
        
    /// Exception Link Register (ELR_EL1).
    /// The address where the exception occurred and where execution will resume.
    public var elr: UInt64
    
    /// Saved Process Status Register (SPSR_EL1).
    /// Holds the processor state (PSTATE) at the time of the exception.
    public var spsr: UInt64
    
    /// Exception Syndrome Register (ESR_EL1).
    /// Provides information about the cause of the exception.
    public var esr: UInt64
    
    /// Fault Address Register (FAR_EL1).
    /// Holds the virtual address that caused a synchronous exception (e.g., Page Fault).
    public var far: UInt64
    
    /// Stack Pointer for Exception Level 0 (SP_EL0).
    /// Used to track the user-space stack pointer during a syscall or interrupt.
    public var spel0: UInt64
    
    /// Initializes a blank trap frame with all registers set to zero.
    public init() {
        self.x0  = 0; self.x1  = 0; self.x2  = 0; self.x3 = 0
        self.x4  = 0; self.x5  = 0; self.x6  = 0; self.x7 = 0
        self.x8  = 0; self.x9  = 0; self.x10 = 0; self.x11 = 0
        self.x12 = 0; self.x13 = 0; self.x14 = 0; self.x15 = 0
        self.x16 = 0; self.x17 = 0; self.x18 = 0; self.x19 = 0
        self.x20 = 0; self.x21 = 0; self.x22 = 0; self.x23 = 0
        self.x24 = 0; self.x25 = 0; self.x26 = 0; self.x27 = 0
        self.x28 = 0; self.x29 = 0; self.x30 = 0
        
        self.elr = 0; self.spsr = 0; self.esr = 0; self.far = 0; self.spel0 = 0
    }
}
