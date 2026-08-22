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
public struct GICv2: RXAllocatable, InterruptController, Loggable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate GICv2 on the kernel heap"
    
    public static let nameLog : StaticString = "[GIC ]"
    public static let logLevel: LogLevel     = .info

    /// First INTID the architecture reserves (1020...1023).
    ///
    /// Nothing in that window denotes a device: 1023 is what `GICC_IAR`
    /// hands back when there was no interrupt to take, and none of the
    /// four may ever reach `GICC_EOIR`, because no priority was raised
    /// for them to drop.
    public static let reservedInterruptBase: UInt32 = 1020

    /// First INTID that is a Shared Peripheral Interrupt.
    ///
    /// Below it sit the SGIs (0...15) and the PPIs (16...31), which are
    /// banked per CPU: they are delivered to the core that owns the bank
    /// and therefore need no distributor targeting.
    private static let firstSPI: UInt32 = 32

    /// Virtual Timer PPI. Armed at construction because it drives
    /// preemption, so the scheduler must never depend on a later caller.
    private static let virtualTimerID: UInt32 = 27

    // Distributor registers.
    private static let gicdCTLR     : UInt64 = 0x000
    private static let gicdTYPER    : UInt64 = 0x004
    private static let gicdISENABLER: UInt64 = 0x100
    private static let gicdICENABLER: UInt64 = 0x180
    private static let gicdITARGETSR: UInt64 = 0x800
    private static let gicdICFGR    : UInt64 = 0xC00

    // CPU interface registers.
    private static let giccCTLR: UInt64 = 0x000
    private static let giccPMR : UInt64 = 0x004
    private static let giccIAR : UInt64 = 0x00C
    private static let giccEOIR: UInt64 = 0x010

    private let gicd: UnsafeMutablePointer<UInt32>
    private let gicc: UnsafeMutablePointer<UInt32>

    /// Exclusive upper bound on every INTID this distributor implements.
    ///
    /// Read from the hardware instead of assumed, because it is the only
    /// thing that keeps an out-of-range `id` from being turned into a
    /// store past the end of the 4 KiB GICD window.
    private let interruptCount: UInt32

    /// Mask of "this CPU interface", as the distributor numbers it.
    private let cpuTargetMask: UInt32

    public init(
        dBase: UInt64,
        cBase: UInt64
    ) {
        
        guard dBase <= VirtualMemoryManager.maxPhysicalAddress,
              cBase <= VirtualMemoryManager.maxPhysicalAddress else {
            Arch.CPU.panic("GIC base address out of range in the device tree")
        }

        let gicdPtr = UnsafeMutablePointer<UInt32>(
            bitPattern: UInt(dBase + VirtualMemoryManager.physicalOffset)
        )!
        let giccPtr = UnsafeMutablePointer<UInt32>(
            bitPattern: UInt(cBase + VirtualMemoryManager.physicalOffset)
        )!
        self.gicd = gicdPtr
        self.gicc = giccPtr

        
        let itLines = Self.readRegister(ptr: gicdPtr, offset: Self.gicdTYPER) & 0x1F
        self.interruptCount = min(32 * (itLines + 1), Self.reservedInterruptBase)

        let ownTarget = Self.readRegister(ptr: gicdPtr, offset: Self.gicdITARGETSR) & 0xFF
        self.cpuTargetMask = ownTarget == 0 ? 0x01 : ownTarget

        Self.writeRegister(ptr: gicdPtr, offset: Self.gicdCTLR, value: 1)

        enableInterrupt(id: Self.virtualTimerID)

        Self.writeRegister(ptr: giccPtr, offset: Self.giccPMR, value: 0xFF)

        Self.writeRegister(ptr: giccPtr, offset: Self.giccCTLR, value: 1)

        Self.boot("Generic Interrupt Controller ready.")
    }

    /// Arms `id` and, when it is an SPI, points it at this core first.
    ///
    /// The targeting is not optional: GICv2 resets `GICD_ITARGETSR` for
    /// every SPI to "no CPU", so setting the enable bit alone produces a
    /// line that is live in the distributor and can never be delivered.
    public func enableInterrupt(id: UInt32) {
        guard id < interruptCount else {
            Self.warning("enable ignored, INTID \(id) not implemented")
            return
        }

        if id >= Self.firstSPI {
            targetThisCPU(id: id)
        }

        let offset = Self.gicdISENABLER + UInt64(id / 32) * 4

        Self.writeRegister(ptr: gicd, offset: offset, value: 1 << (id % 32))
    }

    /// Masks `id` at the distributor.
    ///
    /// The counterpart every level-triggered source needs: the device
    /// keeps the line asserted until its driver services it, so without a
    /// way to mask a single INTID the same interrupt is re-presented the
    /// instant the handler returns and the core makes no progress.
    public func disableInterrupt(id: UInt32) {
        guard id < interruptCount else { return }

        // GICD_ICENABLER is write-1-to-clear, so no read-modify-write:
        // writing a zero bit leaves that line alone.
        let offset = Self.gicdICENABLER + UInt64(id / 32) * 4

        Self.writeRegister(ptr: gicd, offset: offset, value: 1 << (id % 32))
    }

    /// Selects edge or level detection for `id`.
    ///
    /// Meaningful for SPIs only: `GICD_ICFGR` is read-only for the SGIs,
    /// and implementation-defined (read-only on this platform) for the
    /// PPIs, whose trigger is fixed by the hardware that owns the bank.
    public func configureInterrupt(
        id     : UInt32,
        trigger: InterruptTrigger
    ) {
        guard id < interruptCount else {
            Self.warning("configure ignored, INTID \(id) not implemented")
            return
        }

        guard id >= Self.firstSPI else {
            Self.warning("configure ignored, INTID \(id) has a fixed trigger")
            return
        }

        let offset = Self.gicdICFGR + UInt64(id / 16) * 4
        let shift  = (id % 16) * 2

        var word = Self.readRegister(ptr: gicd, offset: offset)
        word &= ~(UInt32(0b10) << shift)

        if case .edge = trigger {
            word |= UInt32(0b10) << shift
        }

        Self.writeRegister(ptr: gicd, offset: offset, value: word)
    }

    /// Takes the pending interrupt and returns the whole `GICC_IAR` word.
    ///
    /// Not just the INTID: bits 12:10 name the core that sent an SGI, and
    /// `GICC_EOIR` is required to carry that field back unchanged. The word
    /// is therefore what travels, and `intid(of:)` is what narrows it for a
    /// routing decision. Masking on the way out of here is what would break
    /// EOI for SGIs the moment a second core starts sending them.
    public func acknowledgeInterrupt() -> UInt32 {
        Self.readRegister(ptr: gicc, offset: Self.giccIAR) & 0x1FFF
    }

    /// The INTID an acknowledged word denotes, with the CPUID field dropped.
    public static func intid(of ack: UInt32) -> UInt32 {
        ack & 0x3FF
    }

    /// Signals completion of an acknowledged interrupt to the CPU interface.
    ///
    /// Takes the value `acknowledgeInterrupt` returned, unaltered, because
    /// `GICC_EOIR` expects the same INTID *and* CPUID the `GICC_IAR` read
    /// handed over.
    ///
    /// Reserved INTIDs are dropped: the read that produced one took no
    /// interrupt and raised no running priority, so there is nothing to
    /// complete and the write would be UNPREDICTABLE.
    public func endOfInterrupt(ack: UInt32) {
        guard Self.intid(of: ack) < Self.reservedInterruptBase else { return }

        Self.writeRegister(ptr: gicc, offset: Self.giccEOIR, value: ack)
    }


    /// Points the SPI `id` at the core that owns this CPU interface.
    private func targetThisCPU(id: UInt32) {
        // One byte per INTID, four per word, and the neighbours in that
        // word belong to other lines: read-modify-write, never a blind store.
        let offset = Self.gicdITARGETSR + UInt64(id / 4) * 4
        let shift  = (id % 4) * 8

        var word = Self.readRegister(ptr: gicd, offset: offset)
        word &= ~(UInt32(0xFF) << shift)
        word |= cpuTargetMask << shift

        Self.writeRegister(ptr: gicd, offset: offset, value: word)
    }


    private static func readRegister(
        ptr   : UnsafeMutablePointer<UInt32>,
        offset: UInt64
    ) -> UInt32 {
        ptr.advanced(by: Int(offset / 4)).pointee
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
