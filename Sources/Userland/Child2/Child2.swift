//
//  Child2.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    
    print("[ NCHIL ] Spawned and kill my self")

    if let parent = parentEndpoint(), let cap = receive(handle: parent).grantedCap {
        let va = shmMap(handle: cap)
        if va != 0, let p = UnsafeRawPointer(bitPattern: UInt(va)) {
            print(p.load(as: UInt32.self) == 0xCAFE ? "[ NCHIL ] SHM OK" : "[ NCHIL ] SHM FAIL")
        }
    }

    exit(code: 0)
}
