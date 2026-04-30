//
//  CPUInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//


public protocol CPUInterface {
    static func enableInterrupts()
    static func disableInterrupts()
    static func triggerTrap()
    static func nop()
}
