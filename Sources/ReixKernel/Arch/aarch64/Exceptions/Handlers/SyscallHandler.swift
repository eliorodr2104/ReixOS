//
//  SyscallHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/05/2026.
//

/// Dispatches user-space syscalls into kernel actions.
///
/// Holds the injected dependencies (process manager, scheduler) and
/// forwards each trap to the matching `SyscallProvider`. The actual
/// logic of every syscall lives in its own file under
/// `Arch/aarch64/Syscall/Providers/`, conforming to `SyscallProvider`.
/// The dispatcher is intentionally a single compile-time switch — no
/// existential indirection, no dynamic table.
import ReixABI

public struct SyscallHandler: RXAllocatable {

    public static var errorMessageAllocation: StaticString = "Failed to allocate SyscallHandler on the kernel heap"

    private let processManager: UnsafeMutablePointer<ProcessManager>
    private let scheduler     : UnsafeMutablePointer<KernelScheduler>
    private let ipc           : UnsafeMutablePointer<KernelIPC>
    private let ppm           : UnsafeMutablePointer<KernelPPM>

    public init(
        processManager: UnsafeMutablePointer<ProcessManager>,
        scheduler     : UnsafeMutablePointer<KernelScheduler>,
        ipc           : UnsafeMutablePointer<KernelIPC>,
        ppm           : UnsafeMutablePointer<KernelPPM>
    ) {
        self.processManager = processManager
        self.scheduler      = scheduler
        self.ipc            = ipc
        self.ppm            = ppm
    }

    public func handle(
        type : SyscallNumber,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        let context = SyscallContext(
            processManager: processManager,
            scheduler     : scheduler,
            ipc           : ipc,
            ppm           : ppm
        )

        switch type {
            case .exit         : ExitSyscall         .handle(frame: frame, context: context)
            case .yield        : YieldSyscall        .handle(frame: frame, context: context)
            case .putchar      : PutcharSyscall      .handle(frame: frame, context: context)
            case .getPid       : GetPIDSyscall       .handle(frame: frame, context: context)
            case .getParentPid : GetParentPIDSyscall .handle(frame: frame, context: context)
            case .parentEndpoint: GetParentEndpointSyscall.handle(frame: frame, context: context)
            case .reapChild    : ReapChildSyscall    .handle(frame: frame, context: context)
            case .spawnProcess : SpawnProcessSyscall .handle(frame: frame, context: context)
            case .split        : SplitProcessSyscall .handle(frame: frame, context: context)
            case .terminate    : TerminateSyscall    .handle(frame: frame, context: context)
                
            
            // VMA
            case .brk          : BrkSyscall          .handle(frame: frame, context: context)
            case .mmap         : MmapSyscall         .handle(frame: frame, context: context)
            case .munmap       : MunmapSyscall       .handle(frame: frame, context: context)
            case .decommit     : DecommitSyscall     .handle(frame: frame, context: context)
                
                
            // ICP
            case .send          : SendSyscall          .handle(frame: frame, context: context)
            case .receive       : ReceiveSyscall       .handle(frame: frame, context: context)
            case .spawnEndpoint : SpawnEndpointSyscall .handle(frame: frame, context: context)
            case .call          : CallSyscall          .handle(frame: frame, context: context)
            case .reply         : ReplySyscall         .handle(frame: frame, context: context)
            case .replyRecv     : ReplyRecvSyscall     .handle(frame: frame, context: context)
            case .trySend       : TrySendSyscall       .handle(frame: frame, context: context)
            case .tryReceive    : TryReceiveSyscall    .handle(frame: frame, context: context)
            case .receiveTimeout: ReceiveTimeoutSyscall.handle(frame: frame, context: context)
            case .spawnService  : SpawnServiceSyscall  .handle(frame: frame, context: context)
            case .derive        : DeriveSyscall        .handle(frame: frame, context: context)
                

            // SHM
            case .shmCreate     : ShmCreate            .handle(frame: frame, context: context)
            case .shmMap        : ShmMap               .handle(frame: frame, context: context)
                
                
            // Device
            case .deviceCap     : DeviceCapSyscall     .handle(frame: frame, context: context)
            case .mapDevice     : MapDeviceSyscall     .handle(frame: frame, context: context)
                
            default: break
        }
    }
    
    @inline(__always)
    public func killCurrent(
        frame : UnsafeMutablePointer<Arch.TrapFrame>,
        reason: ExitReason
    ) {
        let context = SyscallContext(
            processManager: processManager,
            scheduler     : scheduler,
            ipc           : ipc,
            ppm           : ppm
        )
        
        processManager.pointee.killCurrent(
            frame  : frame,
            reason : reason,
            context: context
        )
    }
}
