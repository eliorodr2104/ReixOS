//
//  RXIO.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/05/2026.
//

@_cdecl("putchar")
public func putchar(ch: UInt8) {
    _ = _syscall(.putchar, UInt64(ch))
}
