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
            // MARK: - First Step, discover physical address
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                kprint(.error, in: "DTB Tree not found.\n")
                Arch.CPU.waitForInterrupt()
            }
            
            // MARK: - Starting boot
            kprint(in: "Hello on ReixOS!\n")

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint(.boot, in: "Initialize Physical Page Manager.")
            
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            kprint(.boot, in: "Initialize Virtual Memory Manager.")
            
            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)
            kprint(.boot, in: "Mapping Physical to Virtual Address on PPM.")
        
            KernelHeap.initialize(ppmPtr: &ppm!)
            kprint(.boot, in: "Initialize Kernel Heap.")
            
            GIC.initialize(
                dBase: platformInfo.gic.gicdBase,
                cBase: platformInfo.gic.giccBase
            )
            kprint(.boot, in: "Initialize Global Interrupt Controller.")
                                    
            ProcessManager.initialize(vmm: &vmm!, ppm: &ppm!)
            kprint(.boot, in: "Initialize Process Manager.")

            AArch64VirtualTimer.ect()
            kprint(.boot, in: "Enable Core Virtual Timer\n")
                                                
        } catch { internalPanic(error) }
        
        
        do {
            try run()
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprint(.message, in: "Kernel is running\n")
        
        do {
            try testProcessLaunch()
        } catch { throw KernelError(error) }
        
        while true {
            Arch.CPU.waitForInterrupt()
        }
    }
    
    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        Arch.CPU.triggerTrap()
    }
    
    private static func testProcessLaunch() throws (ProcessManagerError) {
        kprint(.message, in: "Start Process Launch Test.\n")
        
        // Two programs, this is contains into initdr tar.
        let firstProcess  = try ProcessManager.spawnProcess(filename: "idle.elf")
        let secondProcess = try ProcessManager.spawnProcess(filename: "init.elf")
        
        kprint(.message, in: "Launching Process.\n")
        
        let trapFramePtr = firstProcess.pointee.context!
        let kStackTop    = UInt64(UInt(bitPattern: firstProcess.pointee.kernelStack!))
        
        do {
            try scheduler.addTask(secondProcess)
        } catch { Arch.CPU.panic(error.localizedDescription) }
        
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
