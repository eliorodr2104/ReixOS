//
//  FrameWalker.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

/// The AAPCS64 frame-pointer chain walk, and the three rules that stop it from
/// becoming a second failure on top of the one it was called to explain.
///
/// This was `PanicBacktrace`'s private loop until the tick sampler needed the
/// same walk on a machine that is still running. Nothing in it belongs to
/// either caller, and a second copy would be a second place to get the cycle
/// guard wrong, so the loop lives here and the callers bring only what they do
/// with an address:
///
/// - **Plausibility.** AAPCS64 keeps the stack, and therefore `x29`, 16-byte
///   aligned, so anything else in there is garbage and reading through it would
///   fault inside the caller. This does not make the read safe, it just makes
///   the obvious cases free. What covers the rest is the caller's own guard:
///   the re-entrancy check in `DefaultPanicFormatter` for the panic report, and
///   for the sampler the refusal to walk a chain that is not the kernel's.
/// - **Monotonicity.** Stacks grow down, so a caller's frame sits above its
///   callee's. Following anything else is how an unwinder hangs on a cycle,
///   which is the normal state of affairs after the kind of corruption that
///   gets a panic printed in the first place.
/// - **The cap.** `limit` belongs to the caller: a panic report can afford 32
///   frames on a console nobody is waiting on, and a sampler firing at tick
///   rate can afford four records before it starts evicting the ring it is
///   writing into.
enum FrameWalker {

    /// Follows the chain from `fp`, handing `visit` every return address on it,
    /// innermost frame first, and stopping as soon as `visit` answers `false`.
    ///
    /// A visitor and not a returned list, because there is nowhere to put a
    /// list: one caller runs after the heap has stopped being trustworthy and
    /// the other inside an interrupt, and both consume an address the moment
    /// they are handed it.
    ///
    /// Inlined always, so the closure is never a value with a context to box.
    /// The panic path allocates nothing, and that is the property keeping it
    /// true here.
    @inline(__always)
    static func walk(
        from fp   : UInt64,
        limit     : Int,
        _    visit: (UInt64) -> Bool
    ) {
        var framePointer = fp
        var visited      = 0

        while visited < limit, isPlausible(framePointer) {
            let returnAddress = word(at: framePointer &+ 8)
            let previous      = word(at: framePointer)

            guard returnAddress != 0, visit(returnAddress) else { break }

            visited &+= 1

            guard previous > framePointer else { break }

            framePointer = previous
        }
    }


    /// Cheapest possible sanity check before dereferencing a frame pointer.
    @inline(__always)
    static func isPlausible(_ framePointer: UInt64) -> Bool {
        framePointer != 0 && framePointer & 0xF == 0
    }


    @inline(__always)
    private static func word(at address: UInt64) -> UInt64 {
        UnsafePointer<UInt64>(bitPattern: UInt(address))?.pointee ?? 0
    }
}
