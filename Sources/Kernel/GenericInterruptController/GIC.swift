//
//  GIC.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

public struct GIC {
    
    private static var gicd: UnsafeMutablePointer<UInt32>! // Distributor
    private static var gicc: UnsafeMutablePointer<UInt32>! // CPU Interface
    
    public static func initialize(dBase: UInt64, cBase: UInt64) {
        self.gicd = UnsafeMutablePointer<UInt32>(bitPattern: UInt(dBase))
        self.gicc = UnsafeMutablePointer<UInt32>(bitPattern: UInt(cBase))
        
        // Confi Distributor (GICD)
        // Offset 0x000: GICD_CTLR (Control Register)
        writeRegister(ptr: gicd, offset: 0x000, value: 1)
        
        // Offset 0x100: GICD_ISENABLER0 (Interrupt Set-Enable Registers)
        // Start l'ID 27 (Virtual Timer)
        enableInterrupt(id: 27)
        
        // Config CPU Interface (GICC)
        // Offset 0x004: GICC_PMR (Priority Mask)
        writeRegister(ptr: gicc, offset: 0x004, value: 0xFF)
        
        // Offset 0x000: GICC_CTLR (Control Register)
        writeRegister(ptr: gicc, offset: 0x000, value: 1)
    }
    
    public static func enableInterrupt(id: UInt32) {
        let registerIndex = id / 32
        let bit           = id % 32
        let offset        = 0x100 + (UInt64(registerIndex) * 4)
        
        writeRegister(ptr: gicd, offset: offset, value: (1 << bit))
    }
    
    public static func acknowledgeInterrupt() -> UInt32 {
        let iar = gicc.advanced(by: 0x000C / 4).pointee
        let interruptID = iar & 0x3FF
                
        return interruptID
    }
    
    public static func endOfInterrupt(id: UInt32) {
        gicc.advanced(by: 0x0010 / 4).pointee = id
    }
    
    
    private static func writeRegister(ptr: UnsafeMutablePointer<UInt32>, offset: UInt64, value: UInt32) {
        ptr.advanced(by: Int(offset / 4)).pointee = value
    }
}
