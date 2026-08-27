//
//  ClockSetSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// `clockSet(nanoseconds, authority)` syscall provider.
///
/// This one *is* authority. Every timestamp written after it depends on it, and
/// a clock moved backwards makes an ordered record lie about its order. So it
/// takes a capability whose whole content is the right to do this, and holding
/// it is the only way.
///
/// `x0` = nanoseconds, `x1` = the clock capability. Answers `0` on success and
/// `UInt64.max` when the caller does not hold one.
public struct ClockSetSyscall: SyscallProvider {

    public static let number: SyscallNumber = .clockSet

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              frame.pointee.x1 <= UInt64(UInt32.max),
              let capability = metadata.pointee.capsTable.resolve(
                  UInt32(truncatingIfNeeded: frame.pointee.x1)
              ),
              case .clock = capability.target,
              capability.rights.contains(.write)
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        WallClock.set(nanoseconds: frame.pointee.x0)

        frame.pointee.x0 = 0
    }
}
