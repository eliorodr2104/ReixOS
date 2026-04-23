//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: PhysicalPageManager?
    private static var vmm: VirtualMemoryManager?
    public  static var internalPanicMessage: String?

    
    public static func boot(dtbAddress: PhysicalAddress) {
        
        do {
            self.ppm = try PhysicalPageManager(
                dtbRawAddress: dtbAddress
            )
            
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)

            kprint("Root Table Address: 0x%x", vmm!.rootTableAddress)
            CPUArm64.enableMMU(table: self.vmm!.rootTableAddress) // TODO: Crash 
//            self.vmm!.isBootstrapping = false
            
        } catch { internalPanic(error) }
        
        
        do {
            try run()
            
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprintf("Kernel is running")
        
        CPUArm64.waitForInterrupt()
        
//        do {
//            try ppm?.testPPM()
//            
//        } catch { throw KernelError(error) }
    }
    
    private static func internalPanic(_ error: KernelError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
    
    private static func internalPanic(_ error: AllocatorError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
    
    private static func internalPanic(_ error: PPMError) {
        internalPanicMessage = error.localizedDescription
        CPUArm64.triggerTrap()
    }
}
