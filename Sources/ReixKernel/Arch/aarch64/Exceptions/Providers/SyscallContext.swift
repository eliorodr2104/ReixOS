//
//  SyscallContext.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Dependencies passed to every `SyscallProvider` at dispatch time.
///
/// Carrier only: no logic. Built once per syscall trap by the
/// `SyscallHandler` from its own injected pointers and forwarded to
/// the matching provider, so each syscall sees an explicit, testable
/// surface instead of reaching into `Kernel.*` global statics.
public struct SyscallContext {

    public let processManager: UnsafeMutablePointer<ProcessManager>
    public let scheduler     : UnsafeMutablePointer<KernelScheduler>
    public let ipc           : UnsafeMutablePointer<KernelIPC>

    public init(
        processManager: UnsafeMutablePointer<ProcessManager>,
        scheduler     : UnsafeMutablePointer<KernelScheduler>,
        ipc           : UnsafeMutablePointer<KernelIPC>
    ) {
        self.processManager = processManager
        self.scheduler      = scheduler
        self.ipc            = ipc
    }
}
