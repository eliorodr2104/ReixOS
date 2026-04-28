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
public struct UartInfo {
    public var type: UInt32 = 0
    public var _pad: UInt32 = 0
    public var baseAddr: UInt64 = 0
    public var irq: UInt32 = 0
    public var clockFreq: UInt32 = 0
    
    public init() {}
}

@frozen
public struct GicInfo {
    public var gicdBase: UInt64 = 0
    public var giccBase: UInt64 = 0
    
    public init() {}
}

@frozen
public struct PlatformInfo {
    public var dtbBase: UInt64 = 0
    public var dtbSize: UInt32 = 0
    public var _pad1: UInt32 = 0     // <-- PADDING per allineare 'ram' (che inizia con UInt64)
    
    public var ram: MemRegion = MemRegion()
    
    public var uart: UartInfo = UartInfo()
    public var gic: GicInfo = GicInfo()
    
    public var cpuCount: UInt32 = 0
    public var _pad2: UInt32 = 0     // <-- PADDING per allineare i puntatori successivi
    
    // I pointer in 64-bit sono 8 byte
    public var bootargs: UnsafeRawPointer? = nil
    public var stdoutPath: UnsafeRawPointer? = nil
}

@_extern(c, "parse_platform_info")
func _c_parse_platform_info(
    _ ptr: UnsafeRawPointer,
    _ out: UnsafeMutableRawPointer
) -> Int32

public func getPlatformInfo(at address: UnsafeRawPointer?) -> PlatformInfo? {
    guard let address = address else { return nil }
    
    var info = PlatformInfo()
    var result: Int32 = -1
    
    withUnsafeMutablePointer(to: &info) { ptrMem in
        let rawOutPointer = UnsafeMutableRawPointer(ptrMem)
        result = _c_parse_platform_info(address, rawOutPointer)
    }
    
    return result == 0 ? info : nil
}
