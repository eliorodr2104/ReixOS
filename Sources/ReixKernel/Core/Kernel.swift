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


    /// Brings the machine up: platform discovery, then every kernel subsystem in
    /// dependency order, then `run`.
    ///
    /// Each subsystem announces itself at the end of its own initialisation, so
    /// the boot log is ordered by this sequence of statements and by nothing
    /// else. Reordering two constructions here reorders two lines on the serial
    /// console, which is this project's regression test: there is no list of
    /// expected boot messages left anywhere to keep in step with the code.
    public static func boot(dtbRawAddress: PhysicalAddress) {

        do {
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                QemuVirtPlatform.error("DTB Tree not found.")
                Arch.CPU.waitForInterrupt()
            }

            printBootBanner()

            self.ppm = try PhysicalPageManager<BuddyAllocator>()

            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)

            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)


            let heapPage     = try ppm!.alloc(4096, flag: .kernel)
            let heapVirtual  = heapPage.address + VirtualMemoryManager.physicalOffset
            let heapRaw      = UnsafeMutableRawPointer(bitPattern: UInt(heapVirtual))!
            let heapPtr      = heapRaw.bindMemory(to: BucketsHeap.self, capacity: 1)
            heapPtr.initialize(to: BucketsHeap(ppmPtr: &ppm!))
            self.heap = heapPtr


            let gicPtr = heap.pointee.kmalloc(GICv2.self)
            gicPtr.initialize(to: GICv2(
                dBase: platformInfo.gic.gicdBase,
                cBase: platformInfo.gic.giccBase
            ))
            self.gic = gicPtr


            let tarFileSystemPtr = heap.pointee.kmalloc(KernelInternalFileSystem.self)
            tarFileSystemPtr.initialize(
                to: TarFileSystem()
            )
            self.fileSystem = tarFileSystemPtr


            let processManagerPtr = heap.pointee.kmalloc(ProcessManager.self)
            processManagerPtr.initialize(to: ProcessManager(
                vmm       : &vmm!,
                ppm       : &ppm!,
                heap      :  heap,
                fileSystem:  fileSystem
            ))
            self.processManager = processManagerPtr


            let schedulerPtr = heap.pointee.kmalloc(KernelScheduler.self)
            schedulerPtr.initialize(to: RoundRobin())
            self.scheduler = schedulerPtr


            let ipcPtr = heap.pointee.kmalloc(KernelIPC.self)
            ipcPtr.initialize(
                to: KernelIPC(
                    ppm      : &self.ppm!,
                    scheduler: self.scheduler,
                    heap     : self.heap
                )
            )
            self.ipc = ipcPtr


            let syscallHandlerPtr = heap.pointee.kmalloc(SyscallHandler.self)
            syscallHandlerPtr.initialize(to: SyscallHandler(
                processManager: self.processManager,
                scheduler     : self.scheduler,
                ipc           : self.ipc,
                ppm           : &self.ppm!
            ))
            self.syscallHandler = syscallHandlerPtr


            AArch64VirtualTimer.enable()
            kprint()

        } catch { internalPanic(error) }


        do {
            try run()
        } catch { internalPanic(error) }
    }


    private static func run() throws(KernelError) {

        Self.info("Kernel is running.")

        do {
            try jumpUserLand()
        } catch { throw KernelError(error) }

        while true {
            Arch.CPU.idleLoop()
        }
    }

    private static func internalPanic<E: KernelFatal>(_ error: E) {
        internalPanicMessage = error.description
        Arch.CPU.triggerTrap()
    }

    private static func jumpUserLand() throws (ProcessManagerError) {
        
        ProcessManager.info("Starting process launch test.")
        
        let firstProcessPath: StaticString = "Init.elf"
        let firstProcessPathPtr = UnsafeRawPointer(
            firstProcessPath.utf8Start
        ).assumingMemoryBound(to: CChar.self)

        let firstProcess = try processManager.pointee.spawnProcess(path: firstProcessPathPtr)

        processManager.pointee.initProcess = firstProcess

         _ = ipc.pointee.spawnEndpoint(
            for   : firstProcess,
            rights: [.send, .receive, .grant, .spawn],
            owner : Endpoint.kernelOwner
        )
        
        let deviceRegion = DeviceRegion(
            address: Kernel.platformInfo.uart.baseAddr,
            size   : UserSpaceLayout.pageSize
        )
        
        let grantHandle = firstProcess.pointee.metadata.pointee.capsTable.install(
            Capability(
                target: .device(deviceRegion),
                badge : Badge(0),
                rights: [.grant, .read, .write]
            )
        )
        
        firstProcess.pointee.metadata.pointee.deviceCap = grantHandle

        ProcessManager.info("Handing control to user space.")
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


        // Last kernel statement before EL0: from here the timer tick exists to
        // drain the ring, and no kernel line still has to beat user space out.
        LogSink.mode = .deferred

        jump_to_user_mode(
            trapFrame: trapFramePtr,
            rootTable: firstProcess.pointee.addressSpace.rootTablePhysical
        )
    }
}


extension Kernel: Loggable {
    public static let nameLog : StaticString = "[KERN]"
    public static let logLevel: LogLevel     = .info
}
