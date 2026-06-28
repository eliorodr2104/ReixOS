//
//  KernelHeapInterface.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

/// Contract every kernel heap implementation must honour.
///
/// Instance-based by design: a heap owns mutable state (free lists,
/// backing PPM pointer) and must be reachable through a stable pointer
/// so callers can perform mutating allocations without copying the
/// manager. The lifecycle of the instance is owned by `Kernel`.
public protocol KernelHeapInterface {

    init(ppmPtr: UnsafeMutablePointer<KernelPPM>)
    
    mutating func kmalloc(
        _ size        : UInt,
          errorMessage: StaticString
    ) -> UnsafeMutableRawPointer

    mutating func kmalloc<Object: RXAllocatable & ~Copyable>(
        _ type    : Object.Type,
        _ capacity: Int
    ) -> UnsafeMutablePointer<Object>
    
    mutating func kfree(_ ptr: UnsafeMutableRawPointer)
}
