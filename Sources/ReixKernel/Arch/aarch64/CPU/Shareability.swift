//
//  Shareability.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//


public enum Shareability: UInt64 {
    case nonShareable   = 0b00
    case outerShareable = 0b10
    case innerShareable = 0b11
}
