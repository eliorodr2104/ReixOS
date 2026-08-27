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

    /// How many pages a shared region really holds.
    ///
    /// A server maps a window a client granted it and has, until this, only the
    /// client's word for how big it is. The kernel knows, because it made the
    /// region, so the server can stop believing the message and ask.
    case shmPages
    
    
    // Device
    case deviceCap
    case mapDevice


    // Caps
    case capExists
    case capDrop


    // Profiler
    case profileControl
    case procStats


    // Interrupts
    case irqWait
    case irqAck


    // DMA
    case dmaAlloc
    case dmaPhysical


    // Device registers, for windows too small to map
    case deviceRead
    case deviceWrite


    // Buses: carving a window or a line out of one
    case busDeriveDevice
    case busDeriveInterrupt


    // The clock: anybody may read it, only an authority may set it
    case clockNow
    case clockSet


    // Waiting for a device and a request in the same place
    case irqBind


    // Stopping the machine
    case powerOff


    /// Whether a principal is still running.
    ///
    /// A server keeps per-client state keyed on the identity every message
    /// carries, and nothing told it when to let that state go. This is the
    /// question it could not ask.
    case identityAlive
}
