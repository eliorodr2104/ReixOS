//
//  VMAStructure.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

public protocol VMAStructure {
    func search(at address: VirtualAddress) -> UnsafeMutablePointer<VirtualMemoryArea>?
    mutating func insert(_ region: UnsafeMutablePointer<VirtualMemoryArea>)
    func delete(at address: VirtualAddress)
    func findFreeGAP(size: UInt64, alignment: UInt64) -> VirtualAddress?
}
