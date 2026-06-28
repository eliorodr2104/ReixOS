//
//  RXAllocatable.swift
//  ReixOS
//
//  Created by Eliomar on 28/06/2026.
//

/// A type that can be allocated on the kernel heap through `kmalloc`.
///
/// The only requirement, `errorMessageAllocation`, is the panic reason
/// printed when an allocation for this type fails. It is a `StaticString`
/// so the text lives in read-only storage and needs no allocation on the
/// out-of-memory path. A default is provided; conformers override it only
/// to add type-specific detail.
public protocol RXAllocatable {
    static var errorMessageAllocation: StaticString { get }
}

public extension RXAllocatable {
    static var errorMessageAllocation: StaticString { "Kernel heap allocation failed" }
}
