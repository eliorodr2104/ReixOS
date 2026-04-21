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
