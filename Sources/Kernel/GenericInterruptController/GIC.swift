//
//  GIC.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

public struct GIC {
    static let GICD_BASE: UInt64 = VirtualMemoryManager.physicalOffset + 0x08000000 // Distributor
    static let GICC_BASE: UInt64 = VirtualMemoryManager.physicalOffset + 0x08010000 // CPU Interface
    
    public static func initialize() {
        let gicdCtlr      = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICD_BASE))!
        let gicdIsenabler = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICD_BASE + 0x0100))! // Enable Register
        
        let giccCtlr      = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICC_BASE))!
        let giccPmr       = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICC_BASE + 0x0004))! // Priority Mask
        
        // Start distributor
        gicdCtlr.pointee = 1
        
        // Enable interrupt ID 30 (Generic timer)
        gicdIsenabler.pointee = (1 << 30)
        
        // 0xFF is 'use all interrupt'
        giccPmr.pointee = 0xFF
        
        // Start CPU Interface
        giccCtlr.pointee = 1
    }
    
    public static func acknowledgeInterrupt() -> UInt32 {
        let giccIar = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICC_BASE + 0x000C))!
        return giccIar.pointee & 0x3FF
    }
    
    public static func endOfInterrupt(id: UInt32) {
        let giccEoir = UnsafeMutablePointer<UInt32>(bitPattern: UInt(GICC_BASE + 0x0010))!
        giccEoir.pointee = id
    }
}
