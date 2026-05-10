//
//  LoadedELF.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//


public struct LoadedELF {
    public let entryPoint: UInt64
    public let image     : PhysicalPage
    public let loadBase  : UInt64
    public let loadEnd   : UInt64
}
