//
//  SyscallNumber.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

public enum SyscallNumber: UInt64 {

    case exit
    case yield
    case putchar
    case getPid
    case getParentPid
    case spawnProcess
    case reapChild
    case sleep
    case terminate

    case brk
    case mmap
    case munmap
}
