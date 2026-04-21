//
//  main.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

@_silgen_name("_kernel_start")
public var _kernel_start: UInt8

@_silgen_name("_kernel_end")
public var _kernel_end: UInt8

@_cdecl("kernel_main")
public func kernelMain(dtbRawPtr: UInt64) {

    let string = "Hello on ReixOS!"
    kprint(string)
    
    do {
        let ppm = try PhysicalPageManager(dtbRawAddress: dtbRawPtr)
        
        try ppm.testPPM()
        
    } catch {
        switch error {
            case .allocationFailed(let reason):
                kprint(reason.localizedDescription)
                
                switch reason {
                    case .bytesNotValid(let bytes):
                        kprint(UInt64(bytes))
                        kprint()
                        
                    case .addressInvalid(let address):
                        kprint(address)
                        kprint()
                        
                    case .addressRangeInvalid(let from, let to):
                        kprint(from)
                        kprint(to)
                        kprint()
                        
                    case .pageOrderInvalid(let order):
                        kprint(UInt64(order))
                        kprint()
                        
                    default:
                        kprint()
                }
                
            default:
                kprint(error.localizedDescription)
        }
    }
}
