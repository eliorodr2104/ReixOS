//
//  TrapFrame.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


@frozen
public struct TrapFrame {
    var x0,  x1,  x2,  x3,  x4,  x5,  x6,  x7 : UInt64
    var x8,  x9,  x10, x11, x12, x13, x14, x15: UInt64
    var x16, x17, x18, x19, x20, x21, x22, x23: UInt64
    var x24, x25, x26, x27, x28, x29          : UInt64
    var x30  : UInt64
    var elr  : UInt64
    var spsr : UInt64
    var esr  : UInt64
    var far  : UInt64
    var spel0: UInt64
    
    init() {
        x0 = 0
        x1 = 0
        x2 = 0
        x3 = 0
        x4 = 0
        x5 = 0
        x6 = 0
        x7 = 0
        x8 = 0
        x9 = 0
        x10 = 0
        x11 = 0
        x12 = 0
        x13 = 0
        x14 = 0
        x15 = 0
        x16 = 0
        x17 = 0
        x18 = 0
        x19 = 0
        x20 = 0
        x21 = 0
        x22 = 0
        x23 = 0
        x24 = 0
        x25 = 0
        x26 = 0
        x27 = 0
        x28 = 0
        x29 = 0
        x30 = 0
        
        elr   = 0
        spsr  = 0
        esr   = 0
        far   = 0
        spel0 = 0
        
    }
}
