//
//  TrapFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


/// Represents the CPU execution context saved during an exception or interrupt.
///
/// This structure captures the full architectural state that can be changed by
/// kernel code: the general-purpose registers, Q0 through Q31, FPCR/FPSR and
/// the critical exception System Registers.
///
/// - Important: The memory layout of this struct must exactly match the order in
/// which registers are pushed onto the stack by the assembly exception vector code.
@frozen
public struct AArch64TrapFrame: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate AArch64TrapFrame on the kernel heap"
        
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

    /// Full 128-bit FP/SIMD register state. Each register is stored low word
    /// first, matching a little-endian `stp qN, qN+1` in the vector entry.
    public var q0Low,   q0High,  q1Low,   q1High : UInt64
    public var q2Low,   q2High,  q3Low,   q3High : UInt64
    public var q4Low,   q4High,  q5Low,   q5High : UInt64
    public var q6Low,   q6High,  q7Low,   q7High : UInt64
    public var q8Low,   q8High,  q9Low,   q9High : UInt64
    public var q10Low, q10High, q11Low,  q11High: UInt64
    public var q12Low, q12High, q13Low,  q13High: UInt64
    public var q14Low, q14High, q15Low,  q15High: UInt64
    public var q16Low, q16High, q17Low,  q17High: UInt64
    public var q18Low, q18High, q19Low,  q19High: UInt64
    public var q20Low, q20High, q21Low,  q21High: UInt64
    public var q22Low, q22High, q23Low,  q23High: UInt64
    public var q24Low, q24High, q25Low,  q25High: UInt64
    public var q26Low, q26High, q27Low,  q27High: UInt64
    public var q28Low, q28High, q29Low,  q29High: UInt64
    public var q30Low, q30High, q31Low,  q31High: UInt64

    /// Floating-point control and cumulative status for the interrupted code.
    public var fpcr: UInt64
    public var fpsr: UInt64

    /// Copies one complete saved context without lowering the aggregate
    /// assignment to the kernel's byte-at-a-time `memmove` implementation.
    ///
    /// Trap frames are either separate allocations (process context versus
    /// exception stack) or the exact same frame. Partially overlapping frames
    /// are not a valid input. Keeping this operation here ties its fixed-width
    /// word loop to the layout it copies and gives every scheduler path the
    /// same bounded implementation.
    @inline(never)
    public static func copy(
        from source     : UnsafePointer<Self>,
        to   destination: UnsafeMutablePointer<Self>
    ) {
        guard source != UnsafePointer(destination) else { return }

        let wordCount = MemoryLayout<Self>.size / MemoryLayout<UInt64>.size

        source.withMemoryRebound(to: UInt64.self, capacity: wordCount) { sourceWords in
            destination.withMemoryRebound(to: UInt64.self, capacity: wordCount) { destinationWords in
                var index = 0
                while index < wordCount {
                    destinationWords[index]     = sourceWords[index]
                    destinationWords[index + 1] = sourceWords[index + 1]
                    index &+= 2
                }
            }
        }
    }
    
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

        self.q0Low  = 0; self.q0High  = 0; self.q1Low  = 0; self.q1High  = 0
        self.q2Low  = 0; self.q2High  = 0; self.q3Low  = 0; self.q3High  = 0
        self.q4Low  = 0; self.q4High  = 0; self.q5Low  = 0; self.q5High  = 0
        self.q6Low  = 0; self.q6High  = 0; self.q7Low  = 0; self.q7High  = 0
        self.q8Low  = 0; self.q8High  = 0; self.q9Low  = 0; self.q9High  = 0
        self.q10Low = 0; self.q10High = 0; self.q11Low = 0; self.q11High = 0
        self.q12Low = 0; self.q12High = 0; self.q13Low = 0; self.q13High = 0
        self.q14Low = 0; self.q14High = 0; self.q15Low = 0; self.q15High = 0
        self.q16Low = 0; self.q16High = 0; self.q17Low = 0; self.q17High = 0
        self.q18Low = 0; self.q18High = 0; self.q19Low = 0; self.q19High = 0
        self.q20Low = 0; self.q20High = 0; self.q21Low = 0; self.q21High = 0
        self.q22Low = 0; self.q22High = 0; self.q23Low = 0; self.q23High = 0
        self.q24Low = 0; self.q24High = 0; self.q25Low = 0; self.q25High = 0
        self.q26Low = 0; self.q26High = 0; self.q27Low = 0; self.q27High = 0
        self.q28Low = 0; self.q28High = 0; self.q29Low = 0; self.q29High = 0
        self.q30Low = 0; self.q30High = 0; self.q31Low = 0; self.q31High = 0

        self.fpcr = 0; self.fpsr = 0
    }
}
