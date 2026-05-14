//
//  ExceptionType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


/// Represents the four fundamental types of exceptions in the AArch64 architecture.
///
/// These types correspond to the major entry points in the Exception Vector Table (EVT)
/// and determine how the processor transitioned from the interrupted context.
public enum ExceptionType: UInt64 {
    
    /// Synchronous Exception.
    /// Triggered by the execution of an instruction (e.g., SVC, BRK, or a Page Fault).
    case synchronous = 1
    
    /// Standard Interrupt Request (IRQ).
    /// An asynchronous signal from an external peripheral or the generic timer.
    case irq = 0
}
