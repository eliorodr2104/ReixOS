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
public struct ProcessManager: RXObject {
    
    public static var errorMessageAllocation = "Failed to allocate ProcessManager on the kernel heap"

    /// Monotonically increasing PID source. Never reused within a boot.
    private var pidCounter: PID = 0

    private let vmm       : UnsafeMutablePointer<VirtualMemoryManager>
    private let ppm       : UnsafeMutablePointer<KernelPPM>
    private let heap      : UnsafeMutablePointer<BucketsHeap>
    private let fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>

    
    public init(
        vmm       : UnsafeMutablePointer<VirtualMemoryManager>,
        ppm       : UnsafeMutablePointer<KernelPPM>,
        heap      : UnsafeMutablePointer<BucketsHeap>,
        fileSystem: UnsafeMutablePointer<KernelInternalFileSystem>
    ) {
        self.vmm        = vmm
        self.ppm        = ppm
        self.heap       = heap
        self.fileSystem = fileSystem
    }


    public mutating func spawnProcess(path: UnsafePointer<CChar>) throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        
        switch fileSystem.pointee.open(
            path : path,
            flags: .read
        ) {
                
            case .success(let handle):
                
                var addressSpace: AddressSpace
                do {
                    addressSpace = try vmm.pointee.createAddressSpace()
                } catch { throw .creationProcessFailed(error) }

                let vmaManagerPtr = try attachVMAManager(to: &addressSpace)

                var elf: LoadedELF
                do {
                    elf = try ElfParser.loadSegments(
                        handle      : handle,
                        fileSystem  : fileSystem,
                        addressSpace: addressSpace,
                        vmaManager  : vmaManagerPtr,
                        vmm         : vmm,
                        ppm         : ppm
                    )
                } catch {
                    _ = fileSystem.pointee.close(handle: handle)
                    throw .programAddressNotValid // TODO: Change this
                }
                
                
                _ = fileSystem.pointee.close(handle: handle)
                

                let stackPage: PhysicalPage
                do {
                    stackPage = try ppm.pointee.alloc(4096)
                } catch { throw .allocationPageFailed(error) }

                let userStackTop   = UserSpaceLayout.stackTop
                let firstStackPage = userStackTop - UserSpaceLayout.pageSize
                do {
                    try vmm.pointee.mapUserPage(
                        addressSpace: addressSpace,
                        virtual     : firstStackPage,
                        physical    : stackPage.address,
                        flags       : [.present, .userAccess, .pxn, .uxn]
                    )
                } catch { throw .mappingFailed(error) }

                try? vmaManagerPtr.pointee.registerRegion(
                    start      : firstStackPage,
                    size       : UserSpaceLayout.pageSize,
                    permissions: [.read, .write, .user],
                    backing    : .anonymous,
                    flags      : .growDown
                )

                let trapFramePtr = heap.pointee.kmalloc(Arch.TrapFrame.self)
                trapFramePtr.initialize(to: Arch.TrapFrame()) // Create constructor limited
                trapFramePtr.pointee.elr   = elf.entryPoint
                trapFramePtr.pointee.spsr  = 0x0
                trapFramePtr.pointee.spel0 = userStackTop

                let pid = self.pidCounter
                self.pidCounter += 1

                let kStackRaw = heap.pointee.kmalloc(4096)
                let kStackTop = kStackRaw.advanced(by: 4096)

                let initialBreak = (elf.loadEnd + UserSpaceLayout.pageSize - 1) & ~(UserSpaceLayout.pageSize - 1)

                
                let metadataPtr = heap.pointee.kmalloc(ProcessMetadata.self)
                metadataPtr.initialize(to: ProcessMetadata(
                    elfImage    : elf.image,
                    elfLoadBase : elf.loadBase,
                    elfLoadEnd  : elf.loadEnd,
                    programBreak: initialBreak
                ))

                let processPtr = heap.pointee.kmalloc(Process.self)
                processPtr.initialize(to: Process(
                    pid           : pid,
                    addressSpace  : addressSpace,

                    context       : trapFramePtr,
                    kernelStackTop: kStackTop,
                    kernelStackRaw: kStackRaw,

                    metadata      : metadataPtr,
                ))

                vmaManagerPtr.pointee.setInitialBreak(initialBreak)

                return processPtr
                
                
            case .failure(_):
                throw .elfParsingFailed(.invalidMagicNumber)
        }
    }
    
    
    public mutating func spawnProcess() throws(ProcessManagerError) -> UnsafeMutablePointer<Process> {
        
        var addressSpace: AddressSpace
        do {
            addressSpace = try vmm.pointee.createAddressSpace()
        } catch { throw .creationProcessFailed(error) }

        // Fork/split path: the child starts with an EMPTY user address
        // space. Every region — including the stack — is reproduced from
        // the parent (descriptor + page contents) by `cloneRegions`, so we
        // must NOT pre-map or pre-register a stack here: doing so would
        // collide with the parent's stack VMA during the clone and abort it.
        _ = try attachVMAManager(to: &addressSpace)

        let trapFramePtr = heap.pointee.kmalloc(Arch.TrapFrame.self)
        
        trapFramePtr.initialize(to: Arch.TrapFrame())
        trapFramePtr.pointee.elr   = 0
        trapFramePtr.pointee.spsr  = 0x0
        trapFramePtr.pointee.spel0 = UserSpaceLayout.stackTop

        let pid = self.pidCounter
        self.pidCounter += 1

        let kStackRaw = heap.pointee.kmalloc(4096)
        let kStackTop = kStackRaw.advanced(by: 4096)

        let metadataPtr = heap.pointee.kmalloc(ProcessMetadata.self)
        metadataPtr.initialize(to: ProcessMetadata())

        let processPtr = heap.pointee.kmalloc(Process.self)
        processPtr.initialize(to: Process(
            pid           : pid,
            addressSpace  : addressSpace,

            context       : trapFramePtr,
            kernelStackTop: kStackTop,
            kernelStackRaw: kStackRaw,

            metadata      : metadataPtr,
        ))

        return processPtr
    }


    public func releaseAddressSpace(_ process: UnsafeMutablePointer<Process>) throws(PPMError) {

        if let vmaManager = process.pointee.addressSpace.vmaManager {
            vmaManager.pointee.teardown()
            vmaManager.deinitialize(count: 1)

            heap.pointee.kfree(UnsafeMutableRawPointer(vmaManager))
            process.pointee.addressSpace.vmaManager = nil
        }

        // The ELF image is no longer a single contiguous block: it is loaded as
        // individual `.anonymous` pages, already released per page by
        // `teardown` above. So there is no block to free here — doing so would
        // double-free pages teardown just returned.
        if let metadata = process.pointee.metadata {
            metadata.pointee.elfImage    = nil
            metadata.pointee.elfLoadBase = 0
            metadata.pointee.elfLoadEnd  = 0
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

        try vmm.pointee.destroyAddressSpace(
            addressSpace: process.pointee.addressSpace
        )
    }

    /// Final teardown of a process struct after every consumer has read
    /// the exit code from its metadata. Frees the metadata block and the
    /// `Process` struct itself. Callers must ensure the process is no
    /// longer referenced by any scheduler queue.
    public func releaseProcess(_ process: UnsafeMutablePointer<Process>) {
        // Unlink from the parent's children list before the struct is freed.
        // `pushChild` threads the list through the Process structs themselves,
        // so leaving a freed child linked leaves the parent with dangling
        // `firstChild`/sibling pointers into reclaimed heap memory — corrupted
        // on the next `pushChild`.
        if let parent = process.pointee.family.parent {
            parent.pointee.family.removeChild(process)
        }

        if let metadata = process.pointee.metadata {
            metadata.deinitialize(count: 1)
            heap.pointee.kfree(UnsafeMutableRawPointer(metadata))
            process.pointee.metadata = nil
        }

        process.deinitialize(count: 1)
        heap.pointee.kfree(UnsafeMutableRawPointer(process))
    }


    private func attachVMAManager(
        to addressSpace: inout AddressSpace
    ) throws(ProcessManagerError) -> UnsafeMutablePointer<VMAManager> {
        
        let vmaPtr = heap.pointee.kmalloc(VMAManager.self)
        vmaPtr.initialize(to: VMAManager(
            heap             : heap,
            vmm              : vmm,
            ppm              : ppm,
            rootTablePhysical: addressSpace.rootTablePhysical,
            asid             : addressSpace.asid
        ))

        addressSpace.vmaManager = vmaPtr
        return vmaPtr
    }
}
