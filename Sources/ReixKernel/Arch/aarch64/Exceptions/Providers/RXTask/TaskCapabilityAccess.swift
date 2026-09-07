//
//  TaskCapabilityAccess.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

enum TaskCapabilityAccess {

    static func handle(_ raw: UInt64) -> UInt32? {
        guard raw <= UInt64(UInt32.max) else { return nil }
        return UInt32(raw)
    }

    static func task(
        rawHandle: UInt64,
        right    : CapRights,
        current  : UnsafeMutablePointer<Process>
    ) -> (handle: UInt32, capability: Capability, control: TaskControl)? {
        guard let handle = handle(rawHandle),
              let capability = current.pointee.metadata?.pointee.capsTable.resolve(handle),
              capability.rights.contains(right),
              case .task(let control) = capability.target,
              TaskRegistry.isOwned(control, by: current.pointee.identity),
              TaskRegistry.record(control) != nil
        else { return nil }

        return (handle, capability, control)
    }

    static func job(
        rawHandle: UInt64,
        right    : CapRights,
        current  : UnsafeMutablePointer<Process>
    ) -> (handle: UInt32, capability: Capability, control: TaskControl)? {
        guard let handle = handle(rawHandle),
              let capability = current.pointee.metadata?.pointee.capsTable.resolve(handle),
              capability.rights.contains(right),
              case .job(let control) = capability.target,
              TaskRegistry.record(control) != nil
        else { return nil }

        return (handle, capability, control)
    }

    static func status(
        rawHandle: UInt64,
        current  : UnsafeMutablePointer<Process>
    ) -> TaskControl? {
        guard let handle = handle(rawHandle),
              let capability = current.pointee.metadata?.pointee.capsTable.resolve(handle),
              capability.rights.contains(.taskStatus)
        else { return nil }

        switch capability.target {
            case .task(let control):
                guard TaskRegistry.isOwned(control, by: current.pointee.identity) else {
                    return nil
                }
                return TaskRegistry.record(control) == nil ? nil : control

            case .job(let control):
                return TaskRegistry.record(control) == nil ? nil : control

            default:
                return nil
        }
    }
}
