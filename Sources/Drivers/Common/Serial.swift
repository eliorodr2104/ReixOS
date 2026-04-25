//
//  Serial.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

public protocol SerialDriver {
    func write(_ byte: UInt8)
    func read() -> UInt8
}


extension SerialDriver {
    func writeString(_ s: String) {
        for b in s.utf8 { write(b) }
    }
    
    func writeLine(_ s: String) {
        writeString(s)
        write(10) // \n
    }
}
