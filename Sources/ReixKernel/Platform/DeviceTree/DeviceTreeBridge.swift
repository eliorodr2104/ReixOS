//
//  DeviceTreeBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

@_extern(c, "parse_platform_info")
func _c_parse_platform_info(
    _ ptr: UnsafeRawPointer,
    _ out: UnsafeMutableRawPointer
) -> Int32


public func getPlatformInfo(
    _ info: inout PlatformInfo,
    at address: UnsafeRawPointer?
) -> Int32? {
    guard let address = address else { return -1 }
    
    var result: Int32 = -1
    
    withUnsafeMutablePointer(to: &info) { ptrMem in
        let rawOutPointer = UnsafeMutableRawPointer(ptrMem)
        result = _c_parse_platform_info(address, rawOutPointer)
    }
    
    return result
}
