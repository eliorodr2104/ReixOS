//
//  VMAType.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/05/2026.
//

import ReixABI

/// Logical access rights attached to a VMA.
///
/// The set is translated to architectural PTE flags through
/// `toPageFlags()` so the rest of the kernel never has to deal with
/// AArch64-specific bits when reasoning about a VMA.
public struct VMAPermissions: OptionSet {
    public let  rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let none    = VMAPermissions([])
    public static let read    = VMAPermissions(rawValue: 1 << 0)
    public static let write   = VMAPermissions(rawValue: 1 << 1)
    public static let execute = VMAPermissions(rawValue: 1 << 2)
    public static let user    = VMAPermissions(rawValue: 1 << 3)
    public static let shared  = VMAPermissions(rawValue: 1 << 4)

    /// Project the memory rights carried by a capability onto the permissions
    /// of the mapping that capability authorises, or `nil` when it authorises
    /// none at all.
    ///
    /// Lives here, and not inlined in `ShmMap`/`MapDeviceSyscall`, because both
    /// of them have to answer the question identically: two copies of the rule
    /// is two chances for one of them to drift into mapping a region more
    /// permissively than its capability allows.
    ///
    /// A missing `.read` is `nil` rather than an empty set: a present PTE that
    /// grants no access is a fault waiting to happen at the first touch, so the
    /// syscall has to refuse instead of handing back an address. `.user` is
    /// unconditional, everything reached through a capability is mapped for EL0.
    public init?(mapping rights: CapRights) {
        guard rights.contains(.read) else { return nil }

        var permissions: VMAPermissions = [.read, .user]
        if rights.contains(.write) { permissions.insert(.write) }

        self = permissions
    }

    /// Project the logical permissions onto the AArch64 PTE flags the
    /// VMM consumes.
    ///
    /// Invariants applied here:
    ///  - `.pxn` is always set: user pages must never be executable at EL1.
    ///  - `.userAccess` is set only when `.user` is part of the set.
    ///  - `.readOnly` is set when `.write` is missing.
    ///  - `.uxn` is set when `.execute` is missing.
    public func toPageFlags() -> VirtualPageFlags {
        var flags: VirtualPageFlags = [.present, .pxn]

        if contains(.user) {
            flags.insert(.userAccess)
        }

        if !contains(.write) {
            flags.insert(.readOnly)
        }

        if !contains(.execute) {
            flags.insert(.uxn)
        }

        return flags
    }
}
