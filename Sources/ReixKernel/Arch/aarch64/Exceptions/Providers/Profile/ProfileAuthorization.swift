//
//  ProfileAuthorization.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//

import ReixABI

/// The one reader of the profiling rights, for `profileControl` and `procStats`
/// alike.
public enum ProfileAuthorization {

    /// Whether `handle` names a profiler capability carrying `category`.
    ///
    /// The target is checked before the bit, and that check is what the whole
    /// scheme rests on: the category bits share raw values with `read` and
    /// `write`, so an ordinary shared region handle would otherwise read as
    /// profiling authority.
    static func allows(
        _ caps  : CapsTable,
        handle  : UInt32,
        category: CapRights
    ) -> Bool {
        guard let capability = caps.resolve(handle),
              case .profileControl = capability.target else { return false }
        return capability.rights.contains(category)
    }

    /// The same question asked of the running process's own table.
    static func allowsCurrent(handle: UInt32, category: CapRights) -> Bool {
        guard let current = Arch.CPU.getCurrentProcess() else { return false }

        return allows(
            current.pointee.metadata.pointee.capsTable,
            handle  : handle,
            category: category
        )
    }
}
