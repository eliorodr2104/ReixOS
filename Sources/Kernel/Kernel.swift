//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: KernelPPM?
    private static var vmm: VirtualMemoryManager?
    public  static var internalPanicMessage: String?
    public  static var platformInfo = PlatformInfo()

    
    public static func boot(dtbRawAddress: PhysicalAddress) {
        
        do {
            let dtbPointer = UnsafeRawPointer(bitPattern: Int(dtbRawAddress))
            if getPlatformInfo(
                &platformInfo,
                at: dtbPointer
            ) == -1 {
                kprint("Error!")
                KernelCPU.waitForInterrupt()
            }
            kprint("\nHello on ReixOS!")

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint("\nInit PPM!")
            
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            let virtualVBAR = getOfaddressWithSymbol(of: &_evt_start) + VirtualMemoryManager.physicalOffset
            KernelCPU.setVBAR(virtualVBAR)
            kprint("Init VMM!")
        
            KernelHeap.initialize(ppmPtr: &ppm!)
            kprint("Debug Heap init!")
            
            let virtualOffset = VirtualMemoryManager.physicalOffset
            GIC.initialize(dBase: platformInfo.gic.gicdBase + virtualOffset, cBase: platformInfo.gic.giccBase + virtualOffset)
            kprint("Init GIC!")
            
            ProcessManager.initialize(vmm: &vmm!, ppm: &ppm!)
            kprint("Process Manager init!")

            enable_core_timer()
                        
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
            KernelCPU.waitForInterrupt()
        }
        
//        do {
//            try ppm?.testPPM()
//            
//        } catch { throw KernelError(error) }
    }
    
    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        KernelCPU.triggerTrap()
    }
    
    private static func testProcessLaunch() throws (PPMError) {
        let firstProcess = try ProcessManager.spawnProcess()
        
        kprintf("Process PID: %d", firstProcess.pid)
        kprint("Test launch process")
        
        let trapFramePtr  = firstProcess.context!
        let rootTablePhys = firstProcess.addressSpace.rootTablePhysical
        let kStackTop     = UInt64(UInt(bitPattern: firstProcess.kernelStack!)) + 4096
        
        jump_to_user_mode(
            trapFrame     : trapFramePtr,
            rootTable     : rootTablePhys,
            kernelStackTop: kStackTop
        )
        
        // Test print
        kprint("ERRORE: CPU is in Kernel mode.")
    }
    
    private static func testKernelHeap() throws(PPMError) {
        
        guard let ptr1 = try KernelHeap.kmalloc(42) else {
            KernelCPU.panic()
        }
        
        let typedPtr1 = ptr1.assumingMemoryBound(to: UInt64.self)
        typedPtr1.pointee = 0xDEADBEEF_CAFEBABE
        
        guard let ptr2 = try KernelHeap.kmalloc(64) else {
            KernelCPU.panic()
        }
        
        if ptr1 == ptr2 {
            KernelCPU.panic()
        }
        
        KernelHeap.kfree(ptr1)
        
        guard let ptr3 = try KernelHeap.kmalloc(64) else {
            KernelCPU.panic()
        }
        
        if ptr3 != ptr1 {
            KernelCPU.panic()
        }
        
        KernelHeap.kfree(ptr2)
        KernelHeap.kfree(ptr3)
    }
}
