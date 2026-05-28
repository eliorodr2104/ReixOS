//
//  InterruptHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Contract every interrupt-specific handler must satisfy.
///
/// The handler owns the entire reaction to one interrupt ID, including
/// context save, device acknowledge (e.g. timer compare clear),
/// signaling end-of-interrupt to the GIC and the optional context
/// switch when the handler reschedules the running task.
///
/// Handlers are stateless static structs: each concrete type lives in
/// a dedicated file under `Drivers/InterruptController/Handlers` and
/// is registered in `InterruptDispatcher.dispatch(id:frame:)` via a
/// single switch case — no existential indirection.
public protocol InterruptHandler {
    static var  id: UInt32 { get }
    static func handle(frame: UnsafeMutablePointer<Arch.TrapFrame>)
}
