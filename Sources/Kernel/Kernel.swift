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
            kprint("\nInit PPM!")
            
            self.ppm = try PhysicalPageManager(
                dtbRawAddress: dtbAddress
            )
            
            kprint("Init VMM!")
            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            
            kprint("Enabling MMU!")
            CPUArm64.enableMMU(table: self.vmm!.rootTableAddress)
            self.vmm!.isBootstrapping = false
            
        } catch { internalPanic(error) }
        
        
        do {
            try run()
            
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        kprint("\nKernel is running")
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
