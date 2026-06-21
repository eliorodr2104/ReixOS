//
//  child.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import Reix


@_cdecl("_start")
public func main() {
    
    print("[ CHILD ] Hi, this is child process!\n")
    
    if spawnService() == nil {
        print("[ CHILD ] Is Eunuch")
        
    } else {
        print("[ CHILD ] Have balls")
    }


    guard let parentHandle = parentEndpoint() else {
        print("[ CHILD ] Don't have parent endpoint!")
        exit(code: 1)
    }
    
    
    let received = receive(handle: parentHandle)
    guard let nsCap = received.grantedCap else {
        print("[ CHILD ] no NS cap")
        exit(code: 1)
    }

    let nameServer = NameServerClient(endpoint: nsCap)

    guard let processServer = ProcessServerClient(via: nameServer) else {
        print("[ CHILD ] no process server")
        exit(code: 1)
    }
    print("[ CHILD ] lookup OK, Have process server key")

    if let spawned = processServer.spawn(.child2) {
        print("[ CHILD ] Child Pid: ", terminator: " ")
        print(String(spawned.pid))
    }
    
    print("[ CHILD ] Allocate Array of UInt32 for test `malloc`")
    let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: 64)
    buf.initialize(repeating: 0, count: 64)
    buf[3] = 7
    buf.deinitialize(count: 64)
    buf.deallocate()
    
    
    print("[ CHILD ] Instance Object for test `malloc`")
    let roundedRectangle = RoundedRectangle(width: 167, height: 275, cornerRadius: 8)
    roundedRectangle.width        = 17
    roundedRectangle.height       = 27
    roundedRectangle.cornerRadius = 2

    while true { yield() }
}

class RoundedRectangle {
    var width       : UInt
    var height      : UInt
    var cornerRadius: UInt
    
    init(
        width       : UInt,
        height      : UInt,
        cornerRadius: UInt
    ) {
        self.width        = width
        self.height       = height
        self.cornerRadius = cornerRadius
    }
}
