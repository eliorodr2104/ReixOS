//
//  BusAccess.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// Resolving a handle to the bus it names.
enum BusAccess {

    static func authority(
        handle : UInt64,
        of process: UnsafeMutablePointer<Process>
    ) -> (bus: UnsafeMutablePointer<BusAuthority>, rights: CapRights)? {

        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .bus(let bus) = capability.target,
              capability.rights.contains(.derive)
        else { return nil }

        return (bus, capability.rights)
    }
}
