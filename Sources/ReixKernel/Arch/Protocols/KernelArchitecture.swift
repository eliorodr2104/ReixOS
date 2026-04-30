//
//  KernelArchitecture.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


public protocol KernelArchitecture {
    associatedtype CPU: CPUInterface
    associatedtype MMU
    associatedtype TrapFrame
    associatedtype PageTableEntry
}