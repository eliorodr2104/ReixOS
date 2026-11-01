//
//  ELFSegmentCopy.swift
//  ReixOS
//

import ReixABI

/// The destination remains private until every segment and the instruction
/// publication finish. Each read stays within one destination page.
struct ELFSegmentCopy: ResumableOperation {

    typealias Failure = ElfError

    let fileSystem: UnsafeMutablePointer<TarFileSystem>
    let handle    : FileHandle
    let vmm       : UnsafeMutablePointer<VirtualMemoryManager>
    let root      : PhysicalAddress
    let code      : Bool
    var cursor    : VirtualAddress
    var remaining : UInt64

    mutating func step() throws(ElfError) -> Progress {
        guard remaining > 0 else { return .done }

        let size     = UserSpaceLayout.pageSize
        let pageBase = cursor & ~(size - 1)
        let offset   = cursor & (size - 1)
        let chunk    = min(size - offset, remaining)

        guard let physical = vmm.pointee.physicalAddressOf(rootTable: root, virtual: pageBase) else {
            throw .malformedLayout
        }
        let bytes: UnsafeMutablePointer<UInt8> = vmm.pointee.physToVirt(physical)
        let destination = UnsafeMutableRawPointer(bytes.advanced(by: Int(offset)))
        guard (try? fileSystem.pointee.read(handle: handle, buffer: destination, count: chunk)) == chunk else {
            throw .malformedLayout
        }
        if code { Arch.MMU.stageInstructions(destination, size: chunk) }

        cursor += chunk
        remaining -= chunk
        return .more
    }
}
