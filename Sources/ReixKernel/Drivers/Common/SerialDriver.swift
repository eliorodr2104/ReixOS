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

    func writeString(_ s: StaticString) {
        s.withUTF8Buffer { buffer in
            for b in buffer { write(b) }
        }
    }
}
