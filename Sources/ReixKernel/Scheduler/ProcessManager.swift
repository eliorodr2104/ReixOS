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
    
    public static func spawnProcess(filename: StaticString) throws(PPMError) -> UnsafeMutablePointer<Process> {
        guard let vmm = self.vmm, let ppm = self.ppm else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        let cPtr = UnsafeRawPointer(filename.utf8Start).assumingMemoryBound(to: CChar.self)
        let elfRawAddress = parseTar(
            filename  : cPtr,
            tarAddress: kernelPhysicalToVirtual(Kernel.platformInfo.initrdStart)
        )
        guard elfRawAddress != 0 else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        let addressSpace = try vmm.pointee.createAddressSpace()
        let elf          = try ElfParser.loadSegments(
            elfAddress  : elfRawAddress,
            addressSpace: addressSpace,
            vmm         : vmm,
            ppm         : ppm
        )
        
        let userStackSection = try ppm.pointee.alloc(4096)
        let userStackTop: UInt64 = 0x0000007FFFFFE000
        try vmm.pointee.mapUserPage(
            addressSpace: addressSpace,
            virtual: userStackTop,
            physical: userStackSection.address,
            flags: [.present, .userAccess, .pxn, .uxn]
        )
        
        let trapSize = MemoryLayout<Arch.TrapFrame>.stride
        guard let trapRaw  = try KernelHeap.kmalloc(UInt(trapSize)) else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        let trapFramePtr = trapRaw.bindMemory(
            to: Arch.TrapFrame.self,
            capacity: 1
        )
        trapFramePtr.initialize(to: Arch.TrapFrame())
        trapFramePtr.pointee.elr   = elf.entryPoint
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = userStackTop + 4096
        
        
        let pid = Self.pidCounter
        Self.pidCounter += 1
        
        
        guard let kStackRaw = try KernelHeap.kmalloc(4096) else {
            throw .allocationFailed(reason: .fullMemory)
        }
        let kStackTop = kStackRaw.advanced(by: 4096)
        
        
        let processSize = MemoryLayout<Process>.stride
        guard let rawProcessMemory = try KernelHeap.kmalloc(UInt(processSize)) else {
            throw .allocationFailed(reason: .fullMemory)
        }
        
        let processPtr = rawProcessMemory.bindMemory(
            to: Process.self,
            capacity: 1
        )
        processPtr.initialize(to: Process(
            pid                  : pid,
            status               : .new,
            addressSpace         : addressSpace,
            priority             : 1,
            type                 : .user,
            context              : trapFramePtr,
            kernelStack          : kStackTop,
            kernelStackAllocation: kStackRaw,
            userStack            : userStackSection,
            elfImage             : elf.image,
            elfLoadBase          : elf.loadBase,
            elfLoadEnd           : elf.loadEnd
        ))
                
        return processPtr
    }
    
    public static func releaseAddressSpace(_ process: UnsafeMutablePointer<Process>) throws(PPMError) {
        guard let vmm = self.vmm, let ppm = self.ppm else {
            throw .allocationFailed(reason: .fullMemory)
        }
                
        let userStackTop: UInt64 = 0x0000007FFFFFE000
        try vmm.pointee.unmapUserPage(
            addressSpace: process.pointee.addressSpace,
            virtual: userStackTop
        )

        if let userStack = process.pointee.userStack {
            try ppm.pointee.free(userStack)
            process.pointee.userStack = nil
        }

        var elfVirtual = process.pointee.elfLoadBase
        while elfVirtual < process.pointee.elfLoadEnd {
            try vmm.pointee.unmapUserPage(
                addressSpace: process.pointee.addressSpace,
                virtual: elfVirtual
            )
            elfVirtual += VirtualMemoryManager.pageSize
        }

        if let elfImage = process.pointee.elfImage {
            try ppm.pointee.free(elfImage)
            process.pointee.elfImage = nil
        }
        
        if let trapFrame = process.pointee.context {
            KernelHeap.kfree(UnsafeMutableRawPointer(trapFrame))
            process.pointee.context = nil
        }
        
        if let stackAddress = process.pointee.kernelStackAllocation {
            KernelHeap.kfree(UnsafeMutableRawPointer(stackAddress))
            process.pointee.kernelStackAllocation = nil
            process.pointee.kernelStack = nil
        }
        
        try vmm.pointee.destroyAddressSpace(
            addressSpace: process.pointee.addressSpace
        )
    }
}
