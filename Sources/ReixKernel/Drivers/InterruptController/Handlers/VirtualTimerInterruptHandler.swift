//
//  VirtualTimerInterruptHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Drives preemptive scheduling on every Virtual Timer tick.
///
/// On each tick the handler snapshots the running process context into
/// the process trap frame, rearms the core timer (`ect`), signals
/// end-of-interrupt to the GIC and asks the scheduler if the quantum
/// has expired. When it has, the next ready process is selected and
/// its context is loaded back into the exception frame so the return
/// from EL1 lands on the new task.
public struct VirtualTimerInterruptHandler: InterruptHandler {

    public static let id: UInt32 = 27

    public static func handle(frame: UnsafeMutablePointer<Arch.TrapFrame>) {        
        snapshotCurrentContext(frame: frame)

        AArch64VirtualTimer.ect()
        Kernel.gic.pointee.endOfInterrupt(id: id)

        let quantumExpired = Kernel.scheduler.pointee.onTick()

        let systemTicks = Kernel.scheduler.pointee.systemTicks
        if Kernel.ipc.pointee.hasDeadlineDue(at: systemTicks) {
            Kernel.ipc.pointee.checkTimeouts(now: systemTicks)
        }

        guard quantumExpired else { return }

        let outgoingRoot = Arch.CPU.getCurrentProcess()? .pointee.addressSpace.rootTablePhysical

        if let nextProcess = Kernel.scheduler.pointee.selectNextTask() {
            let incomingRoot = nextProcess.pointee.addressSpace.rootTablePhysical

            if incomingRoot != outgoingRoot {
                Arch.MMU.switchUserAddressSpace(
                    incomingRoot,
                    asid: nextProcess.pointee.addressSpace.asid
                )
            }

            frame.pointee = nextProcess.pointee.context!.pointee
        }
    }


    private static func snapshotCurrentContext(
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        guard let current = Arch.CPU.getCurrentProcess() else {
            return
        }

        current.pointee.context?.pointee = frame.pointee
    }
}
