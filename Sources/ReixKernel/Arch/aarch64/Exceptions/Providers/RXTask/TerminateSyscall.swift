//
//  TerminateSyscall.swift
//  ReixOS
//
//  Created by Eliomar on 21/06/2026.
//


import ReixABI

public struct TerminateSyscall: SyscallProvider {
    public static let number: SyscallNumber = .terminate

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let child   = current.pointee.family.removeChild(id: frame.pointee.x0)
        else { frame.pointee.x0 = UInt64.max; return } 

        child.pointee.family.parent = nil
        context.processManager.pointee.killProcess(child, reason: .killed, context: context)
        context.processManager.pointee.releaseProcess(child)
        frame.pointee.x0 = 0
    }
}
