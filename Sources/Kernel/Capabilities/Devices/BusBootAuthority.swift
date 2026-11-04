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
/// said: a list of windows, and the line each one raises.
enum BusBootAuthority {

    @discardableResult
    static func install(
        bus  : borrowing VirtioBusInfo,
        into caps: inout CapsTable,
        heap : UnsafeMutablePointer<KernelHeap>
    ) -> Bool {

        guard bus.isPresent else { return false }

        guard let authority = heap.pointee.kmallocOrNil(BusAuthority.self) else { return false }

        authority.initialize(to: BusAuthority(bus: copy bus))

        let installed = caps.install(
            at: BootCap.virtioBus.rawValue,
            Capability(
                target: .bus(authority),
                badge : Badge(0),

                // `.dma` because a transport is a thing that transfers, and the
                // bus is where that authority enters the system. Which of its
                // windows keeps it is decided further down, by whoever hands one
                // to a driver.
                rights: [.grant, .derive, .read, .write, .dma]
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
