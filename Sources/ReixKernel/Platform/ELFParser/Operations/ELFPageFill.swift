//
//  ELFPageFill.swift
//  ReixOS
//

import ReixABI

/// Fill a registered private range one page at a time. A refused install gives
/// back its own page and charge; the caller unwinds the completed prefix.
struct ELFPageFill: ResumableOperation {

    typealias Failure = ElfError

    let addressSpace: AddressSpace
    let vmm         : UnsafeMutablePointer<VirtualMemoryManager>
    let ppm         : UnsafeMutablePointer<KernelPPM>
    let budget      : UnsafeMutablePointer<FrameBudget>?
    let permissions : VMAPermissions
    var cursor      : VirtualAddress
    let end         : VirtualAddress
    var physical    : PhysicalAddress? = nil

    mutating func step() throws(ElfError) -> Progress {
        guard cursor < end else { return .done }

        if let physical {
            do {
                try vmm.pointee.installUserPage(
                    addressSpace: addressSpace,
                    virtual     : cursor,
                    physical    : physical,
                    flags       : permissions.toPageFlags(),
                    type        : .normal,
                    budget      : budget,
                    batched     : true
                )
            } catch { throw .mappingFailed(error) }
            self.physical = physical + UserSpaceLayout.pageSize
        } else {
            try ElfParser.materialize(
                page        : cursor,
                permissions : permissions,
                addressSpace: addressSpace,
                vmm         : vmm,
                ppm         : ppm,
                budget      : budget
            )
        }

        cursor += UserSpaceLayout.pageSize
        return .more
    }
}
