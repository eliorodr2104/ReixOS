//
//  child.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

import Reix

@_cdecl("_start")
public func main() {
    print("Hi, this is child process!")

    // Ask the kernel for the endpoint it seeded for us at spawn time, instead
    // of assuming a fixed capsTable slot.
    guard let parentHandle = parentEndpoint() else {
        print("Child has no parent endpoint!")
        exit(code: 1)
    }

    let received = receive(handle: parentHandle)
    print("Child received on parent endpoint:", terminator: " ")
    print(String(UInt64(received.message.words[0])))

    exit(code: 0)
}
