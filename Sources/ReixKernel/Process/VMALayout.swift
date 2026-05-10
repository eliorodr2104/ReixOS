//
//  VMALayout.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public protocol VMALayout {
    func insert(_ region: VirtualMemoryArea)
    func remove(at address: VirtualAddress)
    func search(at address: VirtualAddress) -> VirtualMemoryArea?
    func findGAP(size: UInt64, aligment: UInt64) -> VirtualAddress
    func split(at address: VirtualAddress)
}
