//
//  PutcharSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// `putchar(ch)` syscall provider. Writes a single byte to the serial
/// console. Used as the bootstrap user-space stdout while a real I/O
/// stack does not yet exist.
public struct PutcharSyscall: SyscallProvider {

    public static let number: SyscallNumber = .putchar

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        _ = context
        kputc(UInt8(frame.pointee.x0))
    }
}
