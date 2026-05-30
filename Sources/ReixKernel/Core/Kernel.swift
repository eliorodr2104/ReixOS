//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public struct Kernel {
    private static var ppm: KernelPPM?
    private static var vmm: VirtualMemoryManager?

    /// Live kernel heap instance composed at boot.
    ///
    /// The heap owns mutable free-list state and must be reached through a
    /// stable pointer to perform mutating allocations. Bootstrapped on top
    /// of a single PPM page so it never depends on itself (no catch-22).
    public  static var heap: UnsafeMutablePointer<BucketsHeap>!

    /// Live ProcessManager instance composed at boot.
    ///
    /// The manager owns mutable state (PID counter) so callers must reach
    /// it through a stable pointer to perform mutating operations. The
    /// pointer is heap-allocated during `boot` and remains valid for the
    /// whole kernel lifetime. Implicit-unwrapped because reaching it
    /// before `boot` has populated it is a programming error.
    public  static var processManager: UnsafeMutablePointer<ProcessManager>!

    /// Live SyscallHandler instance composed at boot.
    ///
    /// Reached from the exception vector (`@_cdecl swift_exception_handler`)
    /// when a synchronous SVC trap is decoded. Heap-allocated and stable
    /// for the whole kernel lifetime.
    public  static var syscallHandler: UnsafeMutablePointer<SyscallHandler>!

    /// Live interrupt controller instance composed at boot.
    ///
    /// Reached from the IRQ path of the exception vector to acknowledge
    /// pending interrupts and signal end-of-interrupt.
    public  static var gic: UnsafeMutablePointer<GICv2>!

    public  static var scheduler: UnsafeMutablePointer<KernelScheduler>!

    public  static var internalPanicMessage: String?
    public  static var platformInfo = PlatformInfo()


    public static func boot(dtbRawAddress: PhysicalAddress) {

        do {
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                kprint(.error, in: "DTB Tree not found.", by: .boot)
                Arch.CPU.waitForInterrupt()
            }

            printBootBanner()

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint(.boot, in: "Physical Page Manager ready.", by: .ppm)

            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            kprint(.boot, in: "Virtual Memory Manager ready.", by: .vmm)

            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)
            kprint(.boot, in: "Frame metadata mapped into high-half.", by: .ppm)


            let heapPage     = try ppm!.alloc(4096, flag: .kernel)
            let heapVirtual  = heapPage.address + VirtualMemoryManager.physicalOffset
            let heapRaw      = UnsafeMutableRawPointer(bitPattern: UInt(heapVirtual))!
            let heapPtr      = heapRaw.bindMemory(to: BucketsHeap.self, capacity: 1)
            heapPtr.initialize(to: BucketsHeap(ppmPtr: &ppm!))
            self.heap = heapPtr
            kprint(.boot, in: "Kernel heap ready.", by: .heap)


            let gicSize = MemoryLayout<GICv2>.stride
            guard let gicRaw = try heap.pointee.kmalloc(UInt(gicSize)) else {
                Arch.CPU.panic("Failed to allocate GICv2 on the kernel heap")
            }
            let gicPtr = gicRaw.bindMemory(
                to      : GICv2.self,
                capacity: 1
            )
            gicPtr.initialize(to: GICv2(
                dBase: platformInfo.gic.gicdBase,
                cBase: platformInfo.gic.giccBase
            ))
            self.gic = gicPtr
            kprint(.boot, in: "Generic Interrupt Controller ready.", by: .gic)


            let processManagerSize = MemoryLayout<ProcessManager>.stride
            guard let processManagerRaw = try heap.pointee.kmalloc(UInt(processManagerSize)) else {
                Arch.CPU.panic("Failed to allocate ProcessManager on the kernel heap")
            }
            let processManagerPtr = processManagerRaw.bindMemory(
                to: ProcessManager.self,
                capacity: 1
            )
            processManagerPtr.initialize(to: ProcessManager(
                vmm : &vmm!,
                ppm : &ppm!,
                heap: heap
            ))
            self.processManager = processManagerPtr
            kprint(.boot, in: "Process Manager ready.", by: .proc)
            
            
            let schedulerSize = MemoryLayout<KernelScheduler>.stride
            guard let schedulerRaw = try heap.pointee.kmalloc(UInt(schedulerSize)) else {
                Arch.CPU.panic("Failed to allocate Scheduler on the kernel heap")
            }
            let schedulerPtr = schedulerRaw.bindMemory(
                to: RoundRobin.self,
                capacity: 1
            )
            schedulerPtr.initialize(to: RoundRobin())
            self.scheduler = schedulerPtr
            kprint(.boot, in: "Scheduler ready.", by: .sched)


            let syscallHandlerSize = MemoryLayout<SyscallHandler>.stride
            guard let syscallHandlerRaw = try heap.pointee.kmalloc(UInt(syscallHandlerSize)) else {
                Arch.CPU.panic("Failed to allocate SyscallHandler on the kernel heap")
            }
            let syscallHandlerPtr = syscallHandlerRaw.bindMemory(
                to: SyscallHandler.self,
                capacity: 1
            )
            syscallHandlerPtr.initialize(to: SyscallHandler(
                processManager: processManager,
                scheduler     : scheduler
            ))
            self.syscallHandler = syscallHandlerPtr
            kprint(.boot, in: "Syscall Handler ready.", by: .sys)


            AArch64VirtualTimer.ect()
            kprint(.boot, in: "Virtual Timer enabled.", by: .tim)
            kprint()

        } catch { internalPanic(error) }


        do {
            try run()
        } catch { internalPanic(error) }
    }


    private static func run() throws(KernelError) {

        kprint(.info, in: "Kernel is running.", by: .kern)

        do {
            try testProcessLaunch()
        } catch { throw KernelError(error) }

        while true {
            Arch.CPU.waitForInterrupt()
        }
    }

    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        Arch.CPU.triggerTrap()
    }

    private static func testProcessLaunch() throws (ProcessManagerError) {
        kprint(.info, in: "Starting process launch test.", by: .proc)

        let firstProcess  = try processManager.pointee.spawnProcess(filename: "idle.elf")
        let secondProcess = try processManager.pointee.spawnProcess(filename: "init.elf")

        kprint(.info, in: "Handing control to user space.", by: .proc)
        kprint()

        let trapFramePtr = firstProcess.pointee.context!

        do {
            try scheduler.pointee.addTask(secondProcess)
        } catch { Arch.CPU.panic(error.description) }

        firstProcess.pointee.status = .running
        Arch.CPU.setCurrentProcess(
            VirtualAddress(UInt(bitPattern: firstProcess))
        )

        jump_to_user_mode(
            trapFrame: trapFramePtr,
            rootTable: firstProcess.pointee.addressSpace.rootTablePhysical.address
        )
    }
}
