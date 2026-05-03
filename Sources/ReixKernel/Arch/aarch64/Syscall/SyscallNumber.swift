//
//  SyscallNumber.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

public enum SyscallNumber: UInt64 {
    
    // System syscall
    case exit       = 0
    case yield      = 1
    case debugPrint = 2
    
}
