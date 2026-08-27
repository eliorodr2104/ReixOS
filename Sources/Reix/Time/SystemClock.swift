//
//  SystemClock.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// The machine's clock, from userland.
///
/// Reading is free and needs nothing. Setting takes the capability whose whole
/// content is the right to do it, which a process has only if somebody handed
/// it over.
///
/// Named `SystemClock` and not `Clock` because the standard library already has
/// a protocol by that name, and shadowing it would make every future `Clock` in
/// this system a question about which one was meant.
public enum SystemClock {

    /// What time it is, or `Time.unknown` when nobody has said yet.
    @inline(__always)
    public static func now() -> Time {
        Time(nanoseconds: _syscall(.clockNow))
    }


    /// Tells the machine what time it is. `false` when `authority` is not the
    /// capability that allows it.
    @inline(__always)
    public static func set(_ time: Time, authority: UInt32) -> Bool {
        _syscall(.clockSet, time.nanoseconds, UInt64(authority)) == 0
    }
}


public extension Environment {

    /// The right to set the machine's clock, if this process was given it.
    var clock: UInt32? { handle(.clock) }

    /// The right to stop the machine, if this process was given it.
    var power: UInt32? { handle(.power) }
}


/// Stops the machine.
///
/// Everything a shutdown should do first happens before this is called: the
/// kernel does not know what is mounted. It does not come back, and `false`
/// means it was refused rather than that it failed.
@inline(__always)
public func powerOff(authority: UInt32) -> Bool {
    _syscall(.powerOff, UInt64(authority)) == 0
}
