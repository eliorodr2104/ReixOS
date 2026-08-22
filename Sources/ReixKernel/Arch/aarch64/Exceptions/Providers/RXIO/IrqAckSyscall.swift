//
//  IrqAckSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import ReixABI

/// `irqAck(handle, bits)` syscall provider.
///
/// Unmasks the lines named by `bits`, which the kernel masked when it delivered
/// them. The second half of the contract `InterruptDispatcher.deliverToHolder`
/// opens: until this runs, the device may hold its line up as long as it likes
/// without costing the machine anything.
///
/// Only lines this holder actually has masked are unmasked, so a wrong or stale
/// bit is ignored rather than arming a line nobody is ready to service.
public struct IrqAckSyscall: SyscallProvider {

    public static let number: SyscallNumber = .irqAck

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let set     = InterruptAuthority.resolve(
                  handle : frame.pointee.x0,
                  of     : current
              )
                
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        let asked   = UInt8(truncatingIfNeeded: frame.pointee.x1)
        let allowed = asked & set.pointee.masked

        for index in 0..<Int(set.pointee.lineCount)
        where allowed & (UInt8(1) << UInt8(index)) != 0 {
            Kernel.gic.pointee.enableInterrupt(id: set.pointee.lines[index])
        }

        set.pointee.masked &= ~allowed
        frame.pointee.x0    = 0
    }
}
