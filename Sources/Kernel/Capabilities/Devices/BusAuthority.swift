//
//  BusAuthority.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// A whole bus: every transport on it, and the line each one raises.
///
/// The authority a bus process holds so it can hand its children less. Nothing
/// may be driven through it directly: it is not a window and not a line, it is
/// the right to carve one out. `busDeriveDevice` and `busDeriveInterrupt` are
/// the only two things it does, both narrow, and both name a transport by its
/// index rather than by an address or an interrupt number.
///
/// It exists because the alternative was the kernel probing transports to see
/// which were occupied, which is device knowledge in the one place that should
/// have none. The device tree can describe where a bus is; only a read can say
/// what sits on it, and reading is a driver's job.
///
/// It carries `VirtioBusInfo` whole rather than a summary of it. A summary was
/// the bug: two merged ranges made every gap between transports into authority
/// somebody could ask for.
public struct BusAuthority: RXObject {

    public static var errorMessageAllocation: StaticString = "Failed to allocate a bus authority on the kernel heap"

    public var bus: VirtioBusInfo

    public var references: UInt32


    public init(bus: VirtioBusInfo) {
        self.bus        = bus
        self.references = 0
    }
}
