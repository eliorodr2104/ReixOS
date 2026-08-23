//
//  BootCap.swift
//  ReixOS
//

public enum BootCap: UInt32 {
    case parentEndpoint      = 0
    case console             = 1
    case nameServer          = 2
    case spawn               = 3
    case device              = 4
    case nameServerRegistrar = 5
    case profiler            = 6
    case interrupt           = 7

    /// The terminal service endpoint: where a process asks for a line of input.
    /// Not the hardware, which belongs to the terminal server alone.
    case terminal            = 8

    /// The virtio bus, from which a bus process carves the window and the line
    /// of each transport it finds occupied.
    case virtioBus           = 9
}
