//
//  System.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

public struct System {
    
    public static func exit(code: Int32) {
        _syscall(.exit, UInt64(code))
    }
    
    public static func yield() {
        _syscall(.yield)
    }
    
    public static func print(_ message: String) {
        _syscall(.debugPrint, message)
    }
}
