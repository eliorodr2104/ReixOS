//
//  RXObject.swift
//  ReixOS
//
//  Created by Eliomar on 31/05/2026.
//

/// A reference-counted kernel object that a `Capability` can target.
///
/// Refines `RXAllocatable` (every kernel object lives on the kernel heap)
/// and adds an intrusive `references` count. The capability layer retains
/// and releases targets uniformly through `rxRetain`/`rxRelease`, so a new
/// kernel object becomes capability-targetable simply by conforming here:
/// the refcount mechanics come for free and only the type-specific teardown
/// stays at the single `CapTarget` switch.
public protocol RXObject: RXAllocatable {
    var references: UInt32 { get set }
}

@inline(__always)
func rxRetain<Object: RXObject>(_ ptr: UnsafeMutablePointer<Object>) {
    ptr.pointee.references &+= 1
}

@inline(__always)
func rxRelease<Object: RXObject>(_ ptr: UnsafeMutablePointer<Object>) -> Bool {
    guard ptr.pointee.references > 0 else { return false }

    ptr.pointee.references &-= 1
    return ptr.pointee.references == 0
}
