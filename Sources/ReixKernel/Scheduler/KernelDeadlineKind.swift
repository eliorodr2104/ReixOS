//
//  KernelDeadlineKind.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//

@usableFromInline
enum KernelDeadlineKind: UInt8 {
    case none
    case sleep
    case ipc
}
