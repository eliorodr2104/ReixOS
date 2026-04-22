//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: PhysicalPageManager?
    
    public static func boot(dtbAddress: PhysicalAddress) {
        
        do {
            self.ppm = try PhysicalPageManager(
                dtbRawAddress: dtbAddress
            )
            
        } catch { internalPanic(error) }
        
        
        do {
            fatalError()
            try run()
            
        } catch { internalPanic(error) }
    }
    
    
    private static func run() throws(KernelError) {
        
        do {
            try ppm?.testPPM()
            
        } catch { throw KernelError(error) }
    }
    
    private static func internalPanic(_ error: KernelError) -> Never {
        CPUArm64.panic("I needed create localized string for a test.")
    }
    
    private static func internalPanic(_ error: AllocatorError) -> Never {
        CPUArm64.panic(error.localizedDescription)
    }
    
    private static func internalPanic(_ error: PPMError) -> Never {
        CPUArm64.panic(error.localizedDescription)
    }
}
