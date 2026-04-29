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
        guard let vmm = self.vmm, let ppm = self.ppm else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        let addressSpace = try vmm.pointee.createAddressSpace()
        
        let codePageSection  = try ppm.pointee.alloc(4096)
        let stackPageSection = try ppm.pointee.alloc(4096)
        
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x00400000,
            physical    : codePageSection.address,
            flags       : [.present, .userAccess, .pxn]
        )
        
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual     : 0x0000007FFFFFFFF0,
            physical    : stackPageSection.address,
            flags       : [.present, .userAccess, .pxn]
        )
        
        let codePagePointer: UnsafeMutablePointer<UInt32> = vmm.pointee.physToVirt(codePageSection.address)
        codePagePointer.pointee = 0x14000000
        
        let trapFramePage = try ppm.pointee.alloc(4096)
        let trapFramePtr: UnsafeMutablePointer<TrapFrame> = vmm.pointee.physToVirt(trapFramePage.address)
        
        trapFramePtr.pointee.elr   = 0x00400000
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = 0x0000007FFFFFFFF0 + 4096
        
        
        let kStackSize: UInt64 = 16384 // 16 KB
        let kStackPhysical = try ppm.pointee.alloc(Int(kStackSize))
        let kStackRaw: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(kStackPhysical.address)
        let kStackTop = kStackRaw.advanced(by: Int(kStackSize))
        
        let pid = Self.pidCounter
        Self.pidCounter += 1
        
        return Process(
            pid         : pid,
            status      : .ready,
            addressSpace: addressSpace,
            priority    : 1,
            type        : .user,
            context     : trapFramePtr,
            kernelStack : kStackTop
        )
    }
}
