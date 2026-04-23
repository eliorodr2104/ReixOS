//
//  Exception.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/04/2026.
//


public enum Exception: UInt64 {
    case brk = 0x32
    case udf = 0x00
    
    public var message: StaticString {
        switch self {
            case .brk:
                "BRK Instruction"
                
            case .udf:
                "UDF Instruction"
        }
    }
}