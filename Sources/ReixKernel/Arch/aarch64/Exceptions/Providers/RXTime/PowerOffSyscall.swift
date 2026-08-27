//
//  PowerOffSyscall.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

@_silgen_name("psci_hvc")
func psci_hvc(_ function: UInt64, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64


/// `powerOff(authority)` syscall provider.
///
/// Stops the machine, for a caller holding the capability that says it may.
///
/// It does not come back. Everything a shutdown is *supposed* to do first -
/// unmounting the disk above all - happens in userland before this is called,
/// because the kernel does not know what is mounted and has no business
/// learning. This is the last instruction and nothing more.
public struct PowerOffSyscall: SyscallProvider {

    public static let number: SyscallNumber = .powerOff

    /// `SYSTEM_OFF` in the standard firmware interface, the 32-bit calling
    /// convention. The machine has one of these and it is how it is asked.
    private static let systemOff: UInt64 = 0x8400_0008

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let metadata = current.pointee.metadata,
              frame.pointee.x0 <= UInt64(UInt32.max),
              let capability = metadata.pointee.capsTable.resolve(
                  UInt32(truncatingIfNeeded: frame.pointee.x0)
              ),
              case .power = capability.target,
              capability.rights.contains(.write)
        else {
            frame.pointee.x0 = UInt64.max
            return
        }

        Kernel.info("stopping the machine")

        _ = psci_hvc(Self.systemOff, 0, 0, 0)

        // Reached only on a machine whose firmware does not answer, which is
        // worth saying rather than spinning silently.
        Kernel.warning("the machine would not stop")

        frame.pointee.x0 = UInt64.max
    }
}
