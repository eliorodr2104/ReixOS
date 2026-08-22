//
//  InterruptBootAuthority.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// Mints the interrupt authority the device tree describes and installs it in
/// the first process, for the same reason the device window above it is minted
/// here: the blob is the kernel's to read.
///
/// A line is never something a process may ask for by number. If it were, any
/// process could name any INTID and take a device's interrupts out from under
/// the driver that owns them, which is the whole authority this capability
/// exists to hold.
///
/// Nothing in the kernel knows what is on the other end of the line. The set is
/// installed at a boot slot and it is userland's business who ends up holding
/// it and what device they drive with it.
enum InterruptBootAuthority {

    /// Installs a set covering `line`, answering whether it went in.
    ///
    /// A boot that cannot mint it is still a boot: nothing in the kernel drives
    /// a device off this capability, so the failure belongs in the log and not
    /// in the panic path.
    @discardableResult
    static func install(
             line: UInt32,
        into caps: inout CapsTable,
             heap: UnsafeMutablePointer<KernelHeap>,
             gic : UnsafeMutablePointer<GIC>
    ) -> Bool {

        // Zero is what `PlatformInfo` holds when the blob named no interrupt for
        // the device, not a line anybody can be given.
        guard line != 0 else { return false }

        guard let set = heap.pointee.kmallocOrNil(InterruptSet.self) else {
            return false
        }
        set.initialize(to: InterruptSet())

        guard set.pointee.add(line: line) != nil,
              InterruptClaims.claim(line: line, by: set)
        else {
            heap.pointee.kfree(set)
            return false
        }

        let installed = caps.install(
            at: BootCap.interrupt.rawValue,
            Capability(
                target: .interrupt(set),
                badge : Badge(0),
                rights: [.grant, .derive]
            )
        )

        guard installed.installed, installed.displaced == nil else {
            InterruptClaims.releaseAll(of: set)
            heap.pointee.kfree(set)

            return false
        }

        set.pointee.references = 1

        // Armed at the distributor, and silent all the same: the device's own
        // interrupt mask is behind userland's MMIO window, so nothing is raised
        // until whoever ends up holding this turns it on there.
        gic.pointee.enableInterrupt(id: line)

        return true
    }
}
