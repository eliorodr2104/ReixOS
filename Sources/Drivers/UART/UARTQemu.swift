//
//  Uart.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

struct UARTQemu: SerialDriver, @unchecked Sendable {
    
    // Get DR & FR to DTB
    private let dataReg = UnsafeMutablePointer<UInt64>(bitPattern: 0x09000000) // Data Register
    private let flagReg = UnsafePointer<UInt64>(bitPattern: 0x09000018)        // Flag Register
    
    private let txFullBit: UInt8 = 0x20 // Bit 5: Transmit FIFO Full
    
    func write(_ byte: UInt8) {
        guard let dataReg = dataReg, let flagReg = flagReg else { return }
        
        while true {
            let flags = flagReg.pointee
            
            if (flags & UInt64(txFullBit)) == 0 {
                break
            }
            
            KernelCPU.nop()
        }
        
        dataReg.pointee = UInt64(byte)
    }
    
    func read() -> UInt8 {
        return 10
    }
}
