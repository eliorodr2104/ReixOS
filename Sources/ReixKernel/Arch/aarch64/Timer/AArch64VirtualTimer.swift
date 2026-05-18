//
//  HardwareTimer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct AArch64VirtualTimer: HardwareTimerInterface {
    
    public static func ect() {
        enable_core_timer()
    }
}
