//
//  BootCap.swift
//  ReixOS
//
//  Well-known capability slots seeded into a process at spawn time. The handle
//  index doubles as the slot identity, shared between kernel and userland.
//

public enum BootCap: UInt32 {
    case parentEndpoint = 0
    case console        = 1
    case nameServer     = 2
    case spawn          = 3
    case device         = 4
}
