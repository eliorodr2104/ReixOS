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
    
    /// Part of the contract, not an implementation detail of one heap: the two
    /// `kmalloc` requirements above return non-optionally and can only report
    /// exhaustion by panicking, so any heap plugged in here must also offer the
    /// failable form the syscall paths need. Without it, swapping the
    /// implementation would silently reintroduce a userland-triggerable panic.
    mutating func kmallocOrNil(_ size: UInt) -> UnsafeMutableRawPointer?

    mutating func kmallocOrNil<Object: RXAllocatable & ~Copyable>(
        _ type    : Object.Type,
        _ capacity: Int
    ) -> UnsafeMutablePointer<Object>?

    mutating func kfree(_ ptr: UnsafeMutableRawPointer)

    mutating func kfree<Object: ~Copyable>(
        _ ptr: UnsafeMutablePointer<Object>,
        count: Int
    )
}
