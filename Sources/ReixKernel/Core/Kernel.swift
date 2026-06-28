//
//  Kernel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

import ReixABI

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
    
    public  static var ipc: UnsafeMutablePointer<KernelIPC>!
    
    public  static var fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>!

    public  static var internalPanicMessage: String?
    public  static var platformInfo = PlatformInfo()


    public static func boot(dtbRawAddress: PhysicalAddress) {

        do {
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                kprint(.error, "DTB Tree not found.", by: .boot)
                Arch.CPU.waitForInterrupt()
            }

            printBootBanner()

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint(.boot, "Physical Page Manager ready.", by: .ppm)

            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            kprint(.boot, "Virtual Memory Manager ready.", by: .vmm)

            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)
            kprint(.boot, "Frame metadata mapped into high-half.", by: .ppm)


            let heapPage     = try ppm!.alloc(4096, flag: .kernel)
            let heapVirtual  = heapPage.address + VirtualMemoryManager.physicalOffset
            let heapRaw      = UnsafeMutableRawPointer(bitPattern: UInt(heapVirtual))!
            let heapPtr      = heapRaw.bindMemory(to: BucketsHeap.self, capacity: 1)
            heapPtr.initialize(to: BucketsHeap(ppmPtr: &ppm!))
            self.heap = heapPtr
            kprint(.boot, "Kernel heap ready.", by: .heap)

                    
            let gicPtr = heap.pointee.kmalloc(GICv2.self)
            gicPtr.initialize(to: GICv2(
                dBase: platformInfo.gic.gicdBase,
                cBase: platformInfo.gic.giccBase
            ))
            self.gic = gicPtr
            kprint(.boot, "Generic Interrupt Controller ready.", by: .gic)
            
            
            let tarFileSystemPtr = heap.pointee.kmalloc(KernelInternalFileSystem.self)
            tarFileSystemPtr.initialize(
                to: TarFileSystem()
            )
            self.fileSystem = tarFileSystemPtr
            kprint(.boot, "Internal File System ready.", by: .fs)
            

            let processManagerPtr = heap.pointee.kmalloc(ProcessManager.self)
            processManagerPtr.initialize(to: ProcessManager(
                vmm       : &vmm!,
                ppm       : &ppm!,
                heap      : heap,
                fileSystem: fileSystem
            ))
            self.processManager = processManagerPtr
            kprint(.boot, "Process Manager ready.", by: .proc)
            
            
            let schedulerPtr = heap.pointee.kmalloc(KernelScheduler.self)
            schedulerPtr.initialize(to: RoundRobin())
            self.scheduler = schedulerPtr
            kprint(.boot, "Scheduler ready.", by: .sched)

            
            let ipcPtr = heap.pointee.kmalloc(KernelIPC.self)
            ipcPtr.initialize(
                to: KernelIPC(
                    ppm      : &self.ppm!,
                    scheduler: self.scheduler,
                    heap     : self.heap
                )
            )
            self.ipc = ipcPtr
            kprint(.boot, "IPC ready.", by: .ipc)
            

            let syscallHandlerPtr = heap.pointee.kmalloc(SyscallHandler.self)
            syscallHandlerPtr.initialize(to: SyscallHandler(
                processManager: self.processManager,
                scheduler     : self.scheduler,
                ipc           : self.ipc,
                ppm           : &self.ppm!
            ))
            self.syscallHandler = syscallHandlerPtr
            kprint(.boot, "Syscall Handler ready.", by: .sys)


            AArch64VirtualTimer.ect()
            kprint(.boot, "Virtual Timer enabled.", by: .tim)
            kprint()

        } catch { internalPanic(error) }


        do {
            try run()
        } catch { internalPanic(error) }
    }


    private static func run() throws(KernelError) {

        kprint(.info, "Kernel is running.", by: .kern)

        do {
            try jumpUserLand()
        } catch { throw KernelError(error) }

        while true {
            Arch.CPU.waitForInterrupt()
        }
    }

    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        Arch.CPU.triggerTrap()
    }

    private static func jumpUserLand() throws (ProcessManagerError) {
        kprint(.info, "Starting process launch test.", by: .proc)
        
        let firstProcessPath: StaticString = "Init.elf"
        let firstProcessPathPtr = UnsafeRawPointer(
            firstProcessPath.utf8Start
        ).assumingMemoryBound(to: CChar.self)

        let firstProcess = try processManager.pointee.spawnProcess(path: firstProcessPathPtr)
        
         _ = ipc.pointee.spawnEndpoint(
            for   : firstProcess,
            rights: [.send, .receive, .grant, .spawn],
            owner : Endpoint.kernelOwner
        )

        kprint(.info, "Handing control to user space.", by: .proc)
        kprint()

        let trapFramePtr = firstProcess.pointee.context!

        firstProcess.pointee.status = .running
        Arch.CPU.setCurrentProcess(
            VirtualAddress(UInt(bitPattern: firstProcess))
        )

        
        kprint("=================================================")
        kprint()
        kprint("                    USER LAND                    ")
        kprint()
        kprint("=================================================")
        kprint()

        
        jump_to_user_mode(
            trapFrame: trapFramePtr,
            rootTable: firstProcess.pointee.addressSpace.rootTablePhysical
        )
    }
}
