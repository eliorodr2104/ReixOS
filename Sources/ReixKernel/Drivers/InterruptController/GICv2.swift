//
//  GIC.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/04/2026.
//

/// ARM GICv2 driver, instance-based.
///
/// Holds the MMIO register windows for the Distributor (GICD) and the
/// CPU Interface (GICC) as stored properties. The single live instance
/// is composed by `Kernel.boot` and reached through `Kernel.gic`.
public struct GICv2: InterruptController {

    private let gicd: UnsafeMutablePointer<UInt32>
    private let gicc: UnsafeMutablePointer<UInt32>

    public init(
        dBase: UInt64,
        cBase: UInt64
    ) {
        let gicdPtr = UnsafeMutablePointer<UInt32>(
            bitPattern: UInt(dBase + VirtualMemoryManager.physicalOffset)
        )!
        let giccPtr = UnsafeMutablePointer<UInt32>(
            bitPattern: UInt(cBase + VirtualMemoryManager.physicalOffset)
        )!
        self.gicd = gicdPtr
        self.gicc = giccPtr

        // Offset 0x000: GICD_CTLR (Control Register)
        Self.writeRegister(ptr: gicdPtr, offset: 0x000, value: 1)

        // Offset 0x100: GICD_ISENABLER0 (Interrupt Set-Enable Registers).
        // Bit 27 enables the Virtual Timer interrupt used by the scheduler.
        let virtualTimerId: UInt32 = 27
        let registerIndex = virtualTimerId / 32
        let bit           = virtualTimerId % 32
        let isEnableOffset: UInt64 = 0x100 + UInt64(registerIndex) * 4
        Self.writeRegister(
            ptr   : gicdPtr,
            offset: isEnableOffset,
            value : 1 << bit
        )

        // Offset 0x004: GICC_PMR (Priority Mask)
        Self.writeRegister(ptr: giccPtr, offset: 0x004, value: 0xFF)

        // Offset 0x000: GICC_CTLR (Control Register)
        Self.writeRegister(ptr: giccPtr, offset: 0x000, value: 1)
    }

    public func enableInterrupt(id: UInt32) {
        let registerIndex = id / 32
        let bit           = id % 32
        let offset        = 0x100 + (UInt64(registerIndex) * 4)

        Self.writeRegister(ptr: gicd, offset: offset, value: (1 << bit))
    }

    public func acknowledgeInterrupt() -> UInt32 {
        let iar         = gicc.advanced(by: 0x000C / 4).pointee
        let interruptID = iar & 0x3FF

        return interruptID
    }

    public func endOfInterrupt(id: UInt32) {
        gicc.advanced(by: 0x0010 / 4).pointee = id
    }


    private static func writeRegister(
        ptr   : UnsafeMutablePointer<UInt32>,
        offset: UInt64,
        value : UInt32
    ) {
        ptr.advanced(by: Int(offset / 4)).pointee = value
    }
}

public typealias GIC = GICv2
