//
//  InterruptAuthority.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// Turning a handle into the interrupt set it names.
///
/// A file of its own because both interrupt syscalls do it and both have to do
/// it identically: `irqWait` and `irqAck` are two halves of one contract, and a
/// handle either names a set to both of them or to neither.
///
/// The check that matters is the last one. Two capabilities are the same size
/// and the same shape, so reading an endpoint handle as an interrupt set is a
/// type confusion the caller would be choosing; matching on the target is what
/// refuses it.
internal enum InterruptAuthority {

    static func resolve(
        handle : UInt64,
        of process: UnsafeMutablePointer<Process>
    ) -> UnsafeMutablePointer<InterruptSet>? {

        guard handle <= UInt64(UInt32.max),
              let metadata   = process.pointee.metadata,
              let capability = metadata.pointee.capsTable.resolve(UInt32(handle)),
              case .interrupt(let set) = capability.target
        else { return nil }

        return set
    }
}
