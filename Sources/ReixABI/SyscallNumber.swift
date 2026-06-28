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
    case parentEndpoint
    case spawnProcess
    case split
    case reapChild
    case sleep
    case terminate

    
    // VMA
    
    case brk
    case mmap
    case munmap
    case decommit
    
    
    // IPC
    case send
    case receive
    case spawnEndpoint
    case call
    case reply
    case replyRecv
    case trySend
    case tryReceive
    case receiveTimeout
    case spawnService
    case derive
    
    
    // SMH
    case shmCreate
    case shmMap
    
    
    // Device
    case deviceCap
    case mapDevice
}
