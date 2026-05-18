//
//  RXIO.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/05/2026.
//

import RXSyscallCore

//@inline(__always)
//public func rxPrint(_ message: String) {
//    _syscall(.debugPrint, message)
//}

@_cdecl("putchar")
public func putchar(ch: UInt8) {
    _ = _syscall(.putchar, UInt64(ch))
}
