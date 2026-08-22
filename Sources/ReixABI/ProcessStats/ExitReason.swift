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
    case memoryFault(FaultCause) // data/instruction abort
    case illegalInstruction      // UDF
    case stackOverflow           // abort in stack guard page
}
