//
//  SyscallABI.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/09/2026.
//


/// How a syscall reads a number userland put in a register.
///
/// A capability handle is thirty-two bits and a register is sixty-four, so the
/// forty-eight of them a handle cannot hold are not a handle. Truncating them
/// away resolves a *different* slot than the one that was named, which is the
/// shape of the bug this exists to make impossible: one caller passing
/// `0x1_0000_0003` and being served slot three.
///
/// One helper and no second copy: every provider that takes a handle, a page
/// count or a length out of a register comes through here, so "too wide" has
/// one answer and every syscall gives it.
public enum SyscallABI {

    /// A capability handle, or nil when the register holds more than one.
    ///
    /// The caller turns nil into its own family's failure value. There is no
    /// single sentinel here on purpose: the memory providers answer
    /// `UInt64.max`, `shmMap` answers `0`, and the task family has a result
    /// enum, and a helper that picked one of them would be wrong twice.
    @inline(__always)
    public static func handle(_ rawValue: UInt64) -> UInt32? {
        guard rawValue <= UInt64(UInt32.max) else { return nil }
        return UInt32(rawValue)
    }


    /// A page count, byte length, index or other thirty-two bit name, refused
    /// past `atMost`.
    ///
    /// The bound is the caller's because it is the caller's ceiling, but the
    /// thirty-two bit clamp is not: a count that does not fit is refused here
    /// rather than wrapped into a small one at the call site.
    @inline(__always)
    public static func count(
        _ rawValue: UInt64,
        atMost    : UInt32
    ) -> UInt32? {
        guard rawValue <= UInt64(atMost) else { return nil }
        return UInt32(rawValue)
    }
}
