//
//  VMA.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//


@frozen
public struct VMA {
    let startAddress  : PhysicalAddress
    let endAddress    : PhysicalAddress
    let contentAddress: PhysicalAddress
}