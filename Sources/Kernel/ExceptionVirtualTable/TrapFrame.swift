//
//  TrapFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


@frozen
public struct TrapFrame {
    var x0, x1, x2, x3, x4, x5, x6, x7: UInt64
    var x8, x9, x10, x11, x12, x13, x14, x15: UInt64
    var x16, x17, x18, x19, x20, x21, x22, x23: UInt64
    var x24, x25, x26, x27, x28, x29: UInt64
    var x30 : UInt64
    var elr : UInt64
    var spsr: UInt64
    var esr : UInt64
}