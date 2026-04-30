//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: KernelPPM?
    private static var vmm: VirtualMemoryManager?
    
    public  static var scheduler: KernelScheduler?
    
    public  static var internalPanicMessage: String?
    public  static var platformInfo = PlatformInfo()

    
    public static func boot(dtbRawAddress: PhysicalAddress) {
        
        do {
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                kprint("Error!")
                Arch.CPU.waitForInterrupt()
            }
            kprint("\nHello on ReixOS!")

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint("\nInit PPM!")
            
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            
            let virtualVBAR = getOfaddressWithSymbol(of: &_evt_start) + VirtualMemoryManager.physicalOffset
            Arch.CPU.setVBAR(virtualVBAR)
            
            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)
            kprint("Init VMM!")
        
            KernelHeap.initialize(ppmPtr: &ppm!)
            kprint("Debug Heap init!")
            
            let virtualOffset = VirtualMemoryManager.physicalOffset
            GIC.initialize(
                dBase: platformInfo.gic.gicdBase + virtualOffset,
                cBase: platformInfo.gic.giccBase + virtualOffset
            )
            kprint("Init GIC!")
            
            ProcessManager.initialize(vmm: &vmm!, ppm: &ppm!)
            kprint("Process Manager init!")

            AArch64VirtualTimer.arm()
            
            scheduler = try RoundRobin()
                        
//            try testKernelHeap()
            
        } catch { internalPanic(error) }
        
        
        do {
            try run()
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprint("\nKernel is running")
        
        do {
            try testProcessLaunch() // Crash when Timer is On
        } catch { throw KernelError(error) }
        
        while true {
            Arch.CPU.waitForInterrupt()
        }
        
//        do {
//            try ppm?.testPPM()
//            
//        } catch { throw KernelError(error) }
    }
    
    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        Arch.CPU.triggerTrap()
    }
    
    private static func testProcessLaunch() throws (PPMError) {
        let firstProcess  = try ProcessManager.spawnProcess()
        let secondProcess = try ProcessManager.spawnProcess()
        
        kprintf("Process PID: %d", firstProcess.pointee.pid)
        kprint("Test launch process")
        
        let trapFramePtr  = firstProcess.pointee.context!
        let rootTablePhys = firstProcess.pointee.addressSpace.rootTablePhysical
        let kStackTop     = UInt64(UInt(bitPattern: firstProcess.pointee.kernelStack!))

//        ProcessManager.setCurrent(
//            pid    : firstProcess.pointee.pid,
//            context: trapFramePtr
//        )
        
        scheduler?.addTask(secondProcess)
        scheduler?.currentProcess = firstProcess
        
        jump_to_user_mode(
            trapFrame     : trapFramePtr,
            rootTable     : rootTablePhys,
            kernelStackTop: kStackTop
        )
        
        // Test print
//        kprint("ERRORE: CPU is in Kernel mode.")
    }
    
    private static func testKernelHeap() throws(PPMError) {
        
        guard let ptr1 = try KernelHeap.kmalloc(42) else {
            Arch.CPU.panic()
        }
        
        let typedPtr1 = ptr1.assumingMemoryBound(to: UInt64.self)
        typedPtr1.pointee = 0xDEADBEEF_CAFEBABE
        
        guard let ptr2 = try KernelHeap.kmalloc(64) else {
            Arch.CPU.panic()
        }
        
        if ptr1 == ptr2 {
            Arch.CPU.panic()
        }
        
        KernelHeap.kfree(ptr1)
        
        guard let ptr3 = try KernelHeap.kmalloc(64) else {
            Arch.CPU.panic()
        }
        
        if ptr3 != ptr1 {
            Arch.CPU.panic()
        }
        
        KernelHeap.kfree(ptr2)
        KernelHeap.kfree(ptr3)
    }
}
