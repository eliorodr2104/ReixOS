//
//  ClockNowSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// `clockNow() -> nanoseconds` syscall provider.
///
/// No capability, and that is not an oversight. What time it is is not a
/// secret: a process that could not ask would be told by one that could, and
/// the only thing gained would be a round trip. Zero comes back when nobody has
/// set the clock yet, and zero is not a date.
public struct ClockNowSyscall: SyscallProvider {

    public static let number: SyscallNumber = .clockNow

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        frame.pointee.x0 = WallClock.now()
    }
}
