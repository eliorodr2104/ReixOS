//
//  InterruptHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Contract every interrupt-specific handler must satisfy.
///
/// The handler owns the entire reaction to one interrupt ID, including
/// context save, device acknowledge (e.g. timer compare clear) and the
/// optional context switch when it reschedules the running task. The
/// controller-level end-of-interrupt is the dispatcher's, not the
/// handler's: see `InterruptDispatcher`.
///
/// Handlers are stateless static structs: each concrete type lives in
/// a dedicated file under `Drivers/InterruptController/Handlers` and
/// is registered in `InterruptDispatcher.dispatch(ack:frame:)` via a
/// single switch case, with no existential indirection.
public protocol InterruptHandler {
    static var  id: UInt32 { get }
    static func handle(frame: UnsafeMutablePointer<Arch.TrapFrame>)
}
