//
//  PagingContext.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// The handles a page operation needs to edit one address space and hand its
/// frames back, carried as one value.
///
/// Read once when a `VMAManager` is built and given to every operation it
/// drives, so a step is never handed a pointer back to the manager for
/// references it can carry itself. The kernel heap is deliberately not here:
/// only the operations that free VMA nodes may touch it, and this value is
/// shared with those that may not.
struct PagingContext {

    let vmm              : UnsafeMutablePointer<VirtualMemoryManager> // 8 Byte
    let ppm              : UnsafeMutablePointer<KernelPPM>            // 8 Byte
    let rootTablePhysical: PhysicalAddress                            // 8 Byte
}
