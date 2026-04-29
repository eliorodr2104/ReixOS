//
//  bridging-header.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

@frozen
public struct MemRegion {
    public var base: UInt64 = 0
    public var size: UInt64 = 0
    
    public init() {}
}


@frozen
public struct GicInfo {
    public var gicdBase: UInt64 = 0
    public var giccBase: UInt64 = 0
    
    public init() {}
}


@frozen
public struct UartInfo {
    public var baseAddr : UInt64 = 0
    public var type     : UInt32 = 0
    public var irq      : UInt32 = 0
    public var clockFreq: UInt32 = 0
    
    public init() {}
}


@frozen
public struct PlatformInfo {
    public var dtbBase   : UInt64    = 0  // 8 byte
    
    public var bootargs  : UnsafeRawPointer? = nil // 8 byte
    public var stdoutPath: UnsafeRawPointer? = nil // 8 byte
    
    public var dtbSize   : UInt32    = 0  // 4 byte
    public var cpuCount  : UInt32    = 0  // 4 byte
    
    public var ram       : MemRegion = MemRegion() // 16 byte
    
    public var uart      : UartInfo  = UartInfo()  // 24 byte
    public var gic       : GicInfo   = GicInfo()   // 16 byhe
}

@_extern(c, "parse_platform_info")
func _c_parse_platform_info(
    _ ptr: UnsafeRawPointer,
    _ out: UnsafeMutableRawPointer
) -> Int32

public func getPlatformInfo(
    _ info: inout PlatformInfo,
    at address: UnsafeRawPointer?
) -> Int32? {
    guard let address = address else { return -1 }
    
    var result: Int32 = -1
    
    withUnsafeMutablePointer(to: &info) { ptrMem in
        let rawOutPointer = UnsafeMutableRawPointer(ptrMem)
        result = _c_parse_platform_info(address, rawOutPointer)
    }
    
    return result
}
