//
//  Uart.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

struct PL011UART: SerialDriver, @unchecked Sendable {
    
    private let drOffset: UInt64 = 0x00
    private let frOffset: UInt64 = 0x18
    private let txFullBit: UInt32 = 0x20 // Bit 5: Transmit FIFO Full

    
    // Get DR & FR to DTB
    private var dataReg: UnsafeMutablePointer<UInt32> {
        UnsafeMutablePointer<UInt32>(
            bitPattern: UInt(
                (Arch.MMU.isMMUEnabled() ? VirtualMemoryManager.physicalOffset : 0) + (Kernel.platformInfo.uart.baseAddr + drOffset)
            )
        )!
        
    } // Data Register
    
    private var flagReg: UnsafePointer<UInt32> {
        UnsafePointer<UInt32>(
            bitPattern: UInt(
                (Arch.MMU.isMMUEnabled() ? VirtualMemoryManager.physicalOffset : 0) + (Kernel.platformInfo.uart.baseAddr + frOffset)
            )
        )!
    } // Flag Register
    
    
    func write(_ byte: UInt8) {
        while true {
            let flags = flagReg.pointee
            
            if (flags & txFullBit) == 0 {
                break
            }
            
            Arch.CPU.nop()
        }
        
        dataReg.pointee = UInt32(byte)
    }
    
    func read() -> UInt8 {
        return 10
    }
}

typealias UARTQemu = PL011UART
