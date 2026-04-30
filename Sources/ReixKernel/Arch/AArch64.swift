//
//  AArch64.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public enum AArch64: KernelArchitecture {
    public typealias CPU            = AArch64CPU
    public typealias MMU            = AArch64MMU
    public typealias TrapFrame      = AArch64TrapFrame
    public typealias PageTableEntry = AArch64PageTableEntry
}
