//
//  InvalidVectorHandler.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.

/// The slots with nothing behind them, numbered as `invalid_entry` numbers them.
///
/// The ids exist only to cross the assembly boundary: the vector table is the
/// one thing that knows which slot fired, and by the time Swift runs the only
/// register that still says so is the one the stub loaded. `ESR_EL1` does not:
/// it describes a synchronous cause and is stale for an IRQ, an FIQ or an
/// SError, which is most of this list.
private enum InvalidVector: UInt64 {

    /// Synchronous exception at the current EL, running on SP_EL0.
    case synchronous = 0

    /// IRQ at the current EL, running on SP_EL0.
    case irq = 1

    /// FIQ, from any EL. The kernel masks F everywhere and handles none.
    case fiq = 2

    /// SError, from any EL. Asynchronous external abort, unrecoverable here.
    case serror = 3

    /// Any exception from AArch32, an execution state this kernel never enters.
    case aarch32 = 4


    var reason: StaticString {
        switch self {
            case .synchronous:
                "Synchronous exception taken on SP_EL0, a stack this kernel never installs"

            case .irq:
                "IRQ taken on SP_EL0, a stack this kernel never installs"

            case .fiq:
                "FIQ taken, and this kernel installs no FIQ handler"

            case .serror:
                "SError taken (asynchronous external abort), which this kernel cannot recover from"

            case .aarch32:
                "Exception from AArch32, an execution state this kernel does not support"
        }
    }
}


/// Panics with the trap frame the vector stub built, naming the slot that fired.
///
/// Declared as returning `Void` and not `Never` only because `@_cdecl` cannot
/// carry an uninhabited result across the C boundary. It does not come back:
/// every path ends in `Arch.CPU.panic`, and the caller parks the CPU in `wfi`
/// should it ever manage to.
///
/// The frame sits on the exception stack rather than wherever SP happened to
/// point, so reading it is safe even when the reason these vectors fired at all
/// is that the interrupted context had no usable stack. Handing it to the panic
/// path is what puts ESR, ELR, FAR, PSTATE and the register dump in the report,
/// for the price of the stores the stub already made.
///
/// - Parameters:
///   - rawFramePointer: the `Arch.TrapFrame` the stub filled in.
///   - vector: the slot id, as `invalid_entry` in ContextSaving.S assigns it.
@_cdecl("swift_invalid_vector")
public func invalidVectorHandler(
    rawFramePointer: UnsafeMutableRawPointer,
    vector         : UInt64
) {

    let frame = rawFramePointer
        .bindMemory(to: Arch.TrapFrame.self, capacity: 1)
        .pointee

    guard let slot = InvalidVector(rawValue: vector) else {
        Arch.CPU.panic("Unnumbered vector with no handler behind it", fp: frame)
    }

    Arch.CPU.panic(slot.reason, fp: frame)
}
