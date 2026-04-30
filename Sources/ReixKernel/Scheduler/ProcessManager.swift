//
//  ProcessManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/04/2026.
//

public struct ProcessManager {
    
    private static var pidCounter: PID = 0
    
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
    
    public static func spawnProcess() throws(PPMError) -> UnsafeMutablePointer<Process> {
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
        
        let processSize = MemoryLayout<Process>.stride
        guard let rawProcessMemory = try KernelHeap.kmalloc(UInt(processSize)) else {
            throw .allocationFailed(reason: .fullMemory)
        }
        let processPtr = rawProcessMemory.bindMemory(to: Process.self, capacity: 1)
        
        processPtr.initialize(
            to: Process(
                pid         : pid,
                status      : .new,
                addressSpace: addressSpace,
                priority    : 1,
                type        : .user,
                context     : trapFramePtr,
                kernelStack : kStackTop,
                kernelStackAllocation: kStackRaw
            )
        )
        
        return processPtr
    }
}
