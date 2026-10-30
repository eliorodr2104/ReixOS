//
//  DmaPhysical.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `dmaPhysical(handle) -> physical base` syscall provider.
///
/// The address a device's descriptor needs. Answered only for a capability
/// minted by `dmaAlloc`, never for an ordinary shared region: the two name the
/// same kind of object, and the difference between them is exactly this
/// question. `UInt64.max` on refusal, which no page-aligned base can be.
///
/// No right is consulted beyond holding the capability. It was minted against a
/// device window and can only have arrived here by being granted, which is an
/// act its holder chose; `grant` and `derive` already govern that.
public struct DmaPhysical: SyscallProvider {

    public static let number: SyscallNumber = .dmaPhysical

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        let handle = frame.pointee.x0

        guard let handle   = SyscallABI.handle(handle),
              let current    = Arch.CPU.getCurrentProcess(),
              let metadata   = current.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(handle),
              case .dma(let region) = capability.target,
              region.pointee.kind == .dma
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        // Page 0 is the whole buffer's base: a `.dma` region is one extent.
        region.pointee.deviceVisible = true
        frame.pointee.x0 = region.pointee.physicalAddress(ofPage: 0)
    }
}
