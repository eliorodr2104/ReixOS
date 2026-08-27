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

    /// The virtio bus, one transport at a time: where each one is and which line
    /// it raises. What sits on them is not discovery's business.
    ///
    /// Much the largest thing in here, and deliberately so: it used to be two
    /// merged ranges, which is smaller and describes a bus that does not exist.
    /// It is read through `transport(at:)` rather than copied, so its size is
    /// paid once in the image and not on every kernel stack frame that touches it.
    public var virtioBus: VirtioBusInfo = VirtioBusInfo() // 520 byte
}
