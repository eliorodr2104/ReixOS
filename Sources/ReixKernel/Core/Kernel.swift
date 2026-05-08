//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: KernelPPM?
    private static var vmm: VirtualMemoryManager?
    
    public  static var scheduler: KernelScheduler = RoundRobin()
    
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
            
            let virtualVBAR = getOfaddressWithSymbol(of: &_evt_start)
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
                                    
//            try testKernelHeap()
            
        } catch { internalPanic(error) }
        
        
        do {
            try run()
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprint("\nKernel is running")
        
        do {
            try testProcessLaunch()
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
        let firstProcess  = try ProcessManager.spawnProcess(filename: "idle.elf")
        let secondProcess = try ProcessManager.spawnProcess(filename: "init.elf")
        
        kprintf("Process PID: %d", firstProcess.pointee.pid)
        kprint("Test launch process")
        
        let trapFramePtr  = firstProcess.pointee.context!
        let kStackTop     = UInt64(UInt(bitPattern: firstProcess.pointee.kernelStack!))
        
        do {
            try scheduler.addTask(secondProcess)
            
        } catch {
            Arch.CPU.panic(error.localizedDescription)
        }
        
        firstProcess.pointee.status = .running
        Arch.CPU.setCurrentProcess(
            VirtualAddress(UInt(bitPattern: firstProcess))
        )
                
        jump_to_user_mode(
            trapFrame     : trapFramePtr,
            rootTable     : firstProcess.pointee.addressSpace.rootTablePhysical.address,
            kernelStackTop: kStackTop
        )
        
    }
}
