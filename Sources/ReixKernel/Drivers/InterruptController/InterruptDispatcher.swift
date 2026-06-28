//
//  InterruptDispatcher.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Routes acknowledged interrupt IDs to the right `InterruptHandler`.
///
/// The router is intentionally a single static switch instead of a
/// dynamic table: handlers are stateless static structs, so resolving
/// `id → concrete type` is a compile-time match. Adding a new device
/// means registering one extra case here next to the new handler file.
/// Unknown IDs are surfaced as warnings so a spurious IRQ does not
/// silently disappear.
public struct InterruptDispatcher {

    private init() {}

    public static func dispatch(
        id   : UInt32,
        frame: UnsafeMutablePointer<Arch.TrapFrame>
    ) {
        switch id {
            case VirtualTimerInterruptHandler.id:
                VirtualTimerInterruptHandler.handle(frame: frame)

            default:
                handleSpurious(id: id)
        }
    }


    private static func handleSpurious(id: UInt32) {
        kprint(.warning, "spurious IRQ id=\(id)", by: .gic)
        Kernel.gic.pointee.endOfInterrupt(id: id)
    }
}
