//
//  ProcessManager.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 26/04/2026.
//

/// Owns the lifecycle of every kernel-managed process.
///
/// Built as an instance struct so its mutable state (PID counter, injected
/// VMM/PPM/Heap pointers) is explicit and testable. The single live
/// instance is composed by `Kernel.boot` and reached through
/// `Kernel.processManager`.
public struct ProcessManager {

    /// Monotonically increasing PID source. Never reused within a boot.
    private var pidCounter: PID = 0

    private let vmm : UnsafeMutablePointer<VirtualMemoryManager>
    private let ppm : UnsafeMutablePointer<KernelPPM>
    private let heap: UnsafeMutablePointer<BucketsHeap>

    public init(
        vmm : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm : UnsafeMutablePointer<KernelPPM>,
        heap: UnsafeMutablePointer<BucketsHeap>
    ) {
        self.vmm  = vmm
        self.ppm  = ppm
        self.heap = heap
    }

    public mutating func spawnProcess(filename: StaticString) throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        let cPtr = UnsafeRawPointer(filename.utf8Start).assumingMemoryBound(to: CChar.self)
        let elfRawAddress = parseTar(
            filename  : cPtr,
            tarAddress: Kernel.platformInfo.initrdStart
        )
        guard elfRawAddress != 0 else { throw .programAddressNotValid }

        var addressSpace: AddressSpace
        do {
            addressSpace = try vmm.pointee.createAddressSpace()
        } catch { throw .creationProcessFailed(error) }

        var elf: LoadedELF
        do {
            elf = try ElfParser.loadSegments(
                elfAddress  : elfRawAddress,
                addressSpace: addressSpace,
                vmm         : vmm,
                ppm         : ppm
            )
        } catch { throw .elfParsingFailed(error) }

        var userStackSection: PhysicalPage
        do {
            userStackSection = try ppm.pointee.alloc(4096)
        } catch { throw .allocationPageFailed(error) }

        let userStackTop: UInt64 = 0x0000007FFFFFE000
        do {
            try vmm.pointee.mapUserPage(
                addressSpace: addressSpace,
                virtual: userStackTop,
                physical: userStackSection.address,
                flags: [.present, .userAccess, .pxn, .uxn]
            )
        } catch { throw .mappingFailed(error) }

        let trapSize = MemoryLayout<Arch.TrapFrame>.stride
        guard let trapRaw = try? heap.pointee.kmalloc(UInt(trapSize)) else {
            throw .heapAllocationFailed
        }

        let trapFramePtr = trapRaw.bindMemory(
            to: Arch.TrapFrame.self,
            capacity: 1
        )
        trapFramePtr.initialize(to: Arch.TrapFrame())
        trapFramePtr.pointee.elr   = elf.entryPoint
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = userStackTop + 4096

        let pid = self.pidCounter
        self.pidCounter += 1

        guard let kStackRaw = try? heap.pointee.kmalloc(4096) else {
            throw .heapAllocationFailed
        }
        let kStackTop = kStackRaw.advanced(by: 4096)

        let metadataSize = MemoryLayout<ProcessMetadata>.stride
        guard let metadataRaw = try? heap.pointee.kmalloc(UInt(metadataSize)) else {
            throw .heapAllocationFailed
        }

        let metadataPtr = metadataRaw.bindMemory(
            to: ProcessMetadata.self,
            capacity: 1
        )
        metadataPtr.initialize(to: ProcessMetadata(
            elfImage   : elf.image,
            elfLoadBase: elf.loadBase,
            elfLoadEnd : elf.loadEnd
        ))

        let processSize = MemoryLayout<Process>.stride
        guard let rawProcessMemory = try? heap.pointee.kmalloc(UInt(processSize)) else {
            throw .heapAllocationFailed
        }

        let processPtr = rawProcessMemory.bindMemory(
            to: Process.self,
            capacity: 1
        )
        processPtr.initialize(to: Process(
            pid           : pid,
            parent        : nil,
            status        : .new,
            addressSpace  : addressSpace,
            priority      : 1,
            type          : .user,
            context       : trapFramePtr,
            kernelStackTop: kStackTop,
            kernelStackRaw: kStackRaw,
            stack         : userStackSection,
            metadata      : metadataPtr
        ))

        return processPtr
    }

    public func releaseAddressSpace(_ process: UnsafeMutablePointer<Process>) throws(PPMError) {
        let metadata = process.pointee.metadata!

        let userStackTop: UInt64 = 0x0000007FFFFFE000
        try vmm.pointee.unmapUserPage(
            addressSpace: process.pointee.addressSpace,
            virtual: userStackTop
        )

        if let userStack = process.pointee.stack {
            try ppm.pointee.free(userStack)
            process.pointee.stack = nil
        }

        var elfVirtual = metadata.pointee.elfLoadBase
        while elfVirtual < metadata.pointee.elfLoadEnd {
            try vmm.pointee.unmapUserPage(
                addressSpace: process.pointee.addressSpace,
                virtual: elfVirtual
            )
            elfVirtual += VirtualMemoryManager.pageSize
        }

        if let elfImage = metadata.pointee.elfImage {
            try ppm.pointee.free(elfImage)
            metadata.pointee.elfImage = nil
        }

        if let trapFrame = process.pointee.context {
            heap.pointee.kfree(UnsafeMutableRawPointer(trapFrame))
            process.pointee.context = nil
        }

        if let stackAddress = process.pointee.kernelStackRaw {
            heap.pointee.kfree(UnsafeMutableRawPointer(stackAddress))
            process.pointee.kernelStackRaw = nil
            process.pointee.kernelStackTop = nil
        }

        metadata.pointee.elfLoadBase = 0
        metadata.pointee.elfLoadEnd  = 0

        try vmm.pointee.destroyAddressSpace(
            addressSpace: process.pointee.addressSpace
        )
    }

    /// Final teardown of a process struct after every consumer has read
    /// the exit code from its metadata. Frees the metadata block and the
    /// `Process` struct itself. Callers must ensure the process is no
    /// longer referenced by any scheduler queue.
    public func releaseProcess(_ process: UnsafeMutablePointer<Process>) {
        if let metadata = process.pointee.metadata {
            metadata.deinitialize(count: 1)
            heap.pointee.kfree(UnsafeMutableRawPointer(metadata))
            process.pointee.metadata = nil
        }

        process.deinitialize(count: 1)
        heap.pointee.kfree(UnsafeMutableRawPointer(process))
    }
}
