//
//  ExitSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//


import ReixABI

/// `exit(code)` syscall provider.
///
/// Releases the running process address space and resources, records
/// the exit code on the cold metadata, optionally wakes a parent that
/// was waiting on it, then yields to the next ready task. When the
/// scheduler has nothing else to run the CPU unmasks IRQs and parks in
/// WFI so the next timer tick or device interrupt can re-enter the
/// scheduler once a task becomes runnable again.
public struct ExitSyscall: SyscallProvider {

    public static let number: SyscallNumber = .exit

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        context.processManager.pointee.killCurrent(
            frame  : frame,
            reason : .exited(frame.pointee.x0),
            context: context
        )
    }
}
