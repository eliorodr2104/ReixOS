//
//  ShmPages.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import ReixABI

/// `shmPages(handle) -> pages` syscall provider.
///
/// How big a shared region actually is, from the only party that knows: the
/// kernel made it and nobody else can change its size.
///
/// It exists because a server was taking a client's word for it. The page count
/// arrived in the attach message, and a client that said four while granting one
/// left the server writing a client's reply into three pages it does not have -
/// which is the server dying on a page fault, at a moment a client chose.
///
/// Zero for a handle that is not a shared region, which is not a size and so
/// cannot be mistaken for one.
public struct ShmPages: SyscallProvider {

    public static let number: SyscallNumber = .shmPages

    public static func handle(
        frame  : UnsafeMutablePointer<Arch.TrapFrame>,
        context: SyscallContext
    ) {
        guard let current = Arch.CPU.getCurrentProcess(),
              let cap = current.pointee.metadata.pointee.capsTable.resolve(
                  UInt32(truncatingIfNeeded: frame.pointee.x0)
              )
        else { frame.pointee.x0 = 0; return }

        switch cap.target {
            case .shared(let region), .dma(let region):
                frame.pointee.x0 = UInt64(region.pointee.pageCount)

            default:
                frame.pointee.x0 = 0
        }
    }
}
