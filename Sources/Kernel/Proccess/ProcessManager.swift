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
    
    public static func spawnProcess() throws(PPMError) -> Process {
        guard let vmm = self.vmm, let ppm = self.ppm else { throw .allocationFailed(reason: .fullMemory) }
        
        let addressSpace = try vmm.pointee.createAddressSpace()
        
        let codePageSection  = try ppm.pointee.alloc(4096)
        let stackPageSection = try ppm.pointee.alloc(4096)
        
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x00400000,
            physical    : codePageSection.address,
            flags       : [.present, .userAccess, .pxn]
        )
//        
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x0000007FFFFFFFF0,
            physical    : stackPageSection.address,
            flags       : [.present, .userAccess, .pxn] // add readWrite
        )
        
        // Write bare metal code ASM for testing
        let codePagePointer: UnsafeMutablePointer<UInt32> = vmm.pointee.physToVirt(codePageSection.address)
        codePagePointer.pointee = 0x14000000
        
        let trapSize = MemoryLayout<TrapFrame>.stride
        // kprintf("Trap size: %d Byte", UInt64(trapSize))
        guard let trapRaw  = try KernelHeap.kmalloc(UInt(trapSize)) else {
            throw .allocationFailed(reason: .fullMemory)
        }

        let trapFramePtr = trapRaw.bindMemory(to: TrapFrame.self, capacity: 1)
        
        trapFramePtr.pointee.elr   = 0x00400000 // Set pc to start code
        trapFramePtr.pointee.spsr  = 0x0        // Set CPU in User Mode
        trapFramePtr.pointee.spel0 = 0x0000007FFFFFFFF0 + 4096 // Top User Stack
        
        let kStackRaw = try KernelHeap.kmalloc(4096)!
        let pid       = Self.pidCounter
        Self.pidCounter += 1
        
        return Process(
            pid         : pid,
            status      : .ready,
            addressSpace: addressSpace,
            priority    : 1,
            type        : .user,
            context     : trapFramePtr,
            kernelStack : kStackRaw
        )
    }
}
