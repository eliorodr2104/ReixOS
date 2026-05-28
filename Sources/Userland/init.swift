//
//  init.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {

    print(String(getPID()))
    print("Hi, this is init process!")
    
    let region = mmap(size: 4096)
    if region != 0 {
        let ptr = UnsafeMutablePointer<UInt8>(bitPattern: UInt(region))!
        ptr.pointee = 0x42
        print(String(UInt64(ptr.pointee)))
        _ = munmap(addr: region, size: 4096)
    }

    exit(code: 0)
}
