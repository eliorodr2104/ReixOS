//
//  BusBootAuthority.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// Mints the bus the device tree described and installs it in the first process.
///
/// One capability for the whole of it, because the kernel has no way to tell one
/// transport from another and no business trying. What it knows is what the blob
/// said: a span of registers and a block of lines.
enum BusBootAuthority {

    @discardableResult
    static func install(
        bus  : VirtioBusInfo,
        into caps: inout CapsTable,
        heap : UnsafeMutablePointer<KernelHeap>
    ) -> Bool {

        guard bus.isPresent else { return false }

        guard let authority = heap.pointee.kmallocOrNil(BusAuthority.self) else { return false }

        authority.initialize(
            to: BusAuthority(
                base     : bus.base,
                size     : bus.size,
                firstLine: bus.firstLine,
                lineCount: bus.lineCount
            )
        )

        let installed = caps.install(
            at: BootCap.virtioBus.rawValue,
            Capability(
                target: .bus(authority),
                badge : Badge(0),
                rights: [.grant, .derive, .read, .write]
            )
        )

        guard installed.installed, installed.displaced == nil else {
            heap.pointee.kfree(authority)
            return false
        }

        authority.pointee.references = 1

        return true
    }
}
