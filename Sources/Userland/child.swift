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

    exit(code: 0)
}
