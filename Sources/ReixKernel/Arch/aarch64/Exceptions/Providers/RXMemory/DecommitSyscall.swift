//
//  DecommitSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//

import ReixABI

/// `decommit(addr, size)` syscall provider.
public struct DecommitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .decommit

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {

        let addr = frame.pointee.x0
        let size = frame.pointee.x1

        guard let current    = Arch.CPU.getCurrentProcess(),
              let vmaManager = current.pointee.addressSpace.vmaManager
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        vmaManager.pointee.decommit(
            addr: addr,
            size: size
        )
        frame.pointee.x0 = 0
    }
}
