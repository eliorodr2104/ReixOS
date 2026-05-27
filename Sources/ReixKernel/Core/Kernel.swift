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

    public  static var scheduler: KernelScheduler = RoundRobin()

    public  static var internalPanicMessage: String?
    public  static var platformInfo = PlatformInfo()


    public static func boot(dtbRawAddress: PhysicalAddress) {

        do {
            // MARK: - First Step, discover physical address
            if !QemuVirtPlatform.discover(into: &platformInfo, at: dtbRawAddress) {
                kprint(.error, in: "DTB Tree not found.\n")
                Arch.CPU.waitForInterrupt()
            }

            // MARK: - Starting boot
            kprint(in: "Hello on ReixOS!\n")
            

            self.ppm = try PhysicalPageManager<BuddyAllocator>()
            kprint(.boot, in: "Initialize Physical Page Manager.")

            self.vmm = try VirtualMemoryManager(ppmPtr: &ppm!)
            kprint(.boot, in: "Initialize Virtual Memory Manager.")

            self.ppm?.applyFramesMetadataVirtualOffset(VirtualMemoryManager.physicalOffset)
            kprint(.boot, in: "Mapping Physical to Virtual Address on PPM.")
            

            let heapPage     = try ppm!.alloc(4096, flag: .kernel)
            let heapVirtual  = heapPage.address + VirtualMemoryManager.physicalOffset
            let heapRaw      = UnsafeMutableRawPointer(bitPattern: UInt(heapVirtual))!
            let heapPtr      = heapRaw.bindMemory(to: BucketsHeap.self, capacity: 1)
            heapPtr.initialize(to: BucketsHeap(ppmPtr: &ppm!))
            self.heap = heapPtr
            kprint(.boot, in: "Initialize Kernel Heap.")
            

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
            kprint(.boot, in: "Initialize Global Interrupt Controller.")
            

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
            kprint(.boot, in: "Initialize Process Manager.")
            

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
                scheduler     : &scheduler
            ))
            self.syscallHandler = syscallHandlerPtr
            kprint(.boot, in: "Initialize Syscall Handler.")
            

            AArch64VirtualTimer.ect()
            kprint(.boot, in: "Enable Core Virtual Timer\n")
            

        } catch { internalPanic(error) }


        do {
            try run()
        } catch { internalPanic(error) }
    }


    private static func run() throws(KernelError) {

        kprint(.message, in: "Kernel is running\n")

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
        kprint(.message, in: "Start Process Launch Test.\n")

        let firstProcess  = try processManager.pointee.spawnProcess(filename: "idle.elf")
        let secondProcess = try processManager.pointee.spawnProcess(filename: "init.elf")

        kprint(.message, in: "Launching Process.\n")

        let trapFramePtr = firstProcess.pointee.context!
        let kStackTop    = UInt64(UInt(bitPattern: firstProcess.pointee.kernelStackTop!))

        do {
            try scheduler.addTask(secondProcess)
        } catch { Arch.CPU.panic(error.localizedDescription) }

        firstProcess.pointee.status = .running
        Arch.CPU.setCurrentProcess(
            VirtualAddress(UInt(bitPattern: firstProcess))
        )

        jump_to_user_mode(
            trapFrame     : trapFramePtr,
            rootTable     : firstProcess.pointee.addressSpace.rootTablePhysical.address,
            kernelStackTop: kStackTop
        )
    }
}
