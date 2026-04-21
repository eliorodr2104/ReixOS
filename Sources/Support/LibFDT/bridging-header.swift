//
//  bridging-header.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

@_extern(c, "get_ram_info")
func _c_get_ram_info(_ ptr: UnsafeRawPointer, _ out: UnsafeRawPointer) -> UInt8

func getRAMInfo(at address: UnsafeRawPointer?) -> RamInfo? {
    var region = RamInfo(start: 0, size: 0, dtbSize: 0)
    guard let address = address else { return region }
       
    var controlVal: UInt8 = 0
    withUnsafePointer(to: &region) { ptrMem in
        controlVal = _c_get_ram_info(address, ptrMem)
    }
    
    return controlVal == 1 ? region : nil
}
