//
//  ExitReason.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

public typealias ExitCode = UInt64

public enum ExitReason {
    case exited(ExitCode)        // exit(code) suicide
    case killed                  // parent terminate child
    case memoryFault(FaultCause, FaultAccess) // refused abort, and what it asked for
    case outOfMemory             // a serviceable fault no frame could back
    case illegalInstruction      // UDF
    case stackOverflow           // abort in stack guard page
}
