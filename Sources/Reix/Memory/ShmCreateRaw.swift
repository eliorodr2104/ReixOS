//
//  ShmCreateRaw.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//

/// Raw two-word layout the kernel writes back: x0 = cap handle, x1 = base VA.
/// Field order MUST match the kernel provider's `frame.x0`/`frame.x1` stores.
internal struct ShmCreateRaw {
    var handle : UInt64 = 0
    var address: UInt64 = 0
}
