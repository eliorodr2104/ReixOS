//
//  PlatformInfo.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//


@frozen
public struct PlatformInfo {
    public var dtbBase    : UInt64    = 0  // 8 byte
    public var initrdStart: UInt64    = 0  // 8 byte
    public var initrdEnd  : UInt64    = 0  // 8 byte
    
    public var bootargs  : UnsafeRawPointer? = nil // 8 byte
    public var stdoutPath: UnsafeRawPointer? = nil // 8 byte
    
    public var dtbSize   : UInt32    = 0  // 4 byte
    public var cpuCount  : UInt32    = 0  // 4 byte
    
    public var ram       : MemRegion = MemRegion() // 16 byte
    
    public var uart      : UartInfo  = UartInfo()  // 24 byte
    public var gic       : GicInfo   = GicInfo()   // 16 byte

    /// The virtio bus: where its transports are and which lines they raise.
    /// What sits on them is not discovery's business.
    public var virtioBus: VirtioBusInfo = VirtioBusInfo() // 24 byte
}
