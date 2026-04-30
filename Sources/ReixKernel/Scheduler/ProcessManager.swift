//
//  ProcessManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/04/2026.
//

public struct ProcessManager {
    
    private static var pidCounter: PID = 0
    private static var currentPid: PID?
    private static var currentContext: UnsafeMutablePointer<Arch.TrapFrame>?
    private static var schedulerTicks: UInt64 = 0
    
    private static var vmm: UnsafeMutablePointer<VirtualMemoryManager>?
    private static var ppm: UnsafeMutablePointer<KernelPPM>?
    
    private init() {}
    
    public static func initialize(
        vmm: UnsafeMutablePointer<VirtualMemoryManager>,
        ppm: UnsafeMutablePointer<KernelPPM>
    ) {
        self.vmm = vmm
        self.ppm = ppm
    }

    public static func setCurrent(
        pid    : PID,
        context: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        self.currentPid = pid
        self.currentContext = context
        self.schedulerTicks = 0
    }

    public static func preemptCurrent(
        framePointer: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        guard let currentContext = self.currentContext else { return }

        currentContext.pointee = framePointer.pointee
        schedulerTicks &+= 1

        if schedulerTicks % 100 == 0 {
            kprint("[PREEMPT]")
        }
    }
    
    public static func spawnProcess() throws(PPMError) -> Process {
        guard let vmm = self.vmm, let ppm = self.ppm else {
            throw .allocationFailed(reason: .fullMemory) // Change to real error
        }
        let addressSpace = try vmm.pointee.createAddressSpace()
        
        let codePageSection  = try ppm.pointee.alloc(4096)
        let userStackSection = try ppm.pointee.alloc(4096)
        
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x00400000,
            physical    : codePageSection.address,
            flags       : [.present, .userAccess, .pxn]
        )

        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x0000007FFFFFE000,
            physical    : userStackSection.address,
            flags       : [.present, .userAccess, .pxn, .uxn]
        )
        
        // Write bare metal code ASM for testing
        let codePagePointer: UnsafeMutablePointer<UInt32> = vmm.pointee.physToVirt(codePageSection.address)
        codePagePointer.pointee = 0x14000000
        
        let trapSize = MemoryLayout<Arch.TrapFrame>.stride
        guard let trapRaw  = try KernelHeap.kmalloc(UInt(trapSize)) else {
            throw .allocationFailed(reason: .fullMemory)
        }

        let trapFramePtr = trapRaw.bindMemory(to: Arch.TrapFrame.self, capacity: 1)
        
        trapFramePtr.pointee.elr   = 0x00400000
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = 0x0000007FFFFFF000
        
        guard let kStackRaw = try KernelHeap.kmalloc(4096) else {
            throw .allocationFailed(reason: .fullMemory)
        }
        let kStackTop = kStackRaw.advanced(by: 4096)
        
        let pid = Self.pidCounter
        Self.pidCounter += 1
        
        return Process(
            pid         : pid,
            status      : .ready,
            addressSpace: addressSpace,
            priority    : 1,
            type        : .user,
            context     : trapFramePtr,
            kernelStack : kStackTop,
            kernelStackAllocation: kStackRaw
        )
    }
}
