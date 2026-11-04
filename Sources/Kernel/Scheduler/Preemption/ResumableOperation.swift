//
//  ResumableOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/08/2026.
//

/// Whether a `ResumableOperation` has work left after the step it just took.
public enum Progress {

    /// `step()` may be called again.
    case more

    /// The operation is finished. Calling `step()` again is a programming
    /// error, and the driver never does.
    case done
}


/// A long kernel operation expressed as a state machine, so that pausing it
/// is possible at all.
///
/// Every exception in this kernel runs with IRQs masked from the vector's
/// `daifset #3` to the `eret`, and nothing at EL1 ever unmasks. An operation
/// that walks 110,000 pages therefore holds every interrupt off for its whole
/// duration. `Preemption.run` fixes that by opening the interrupt window
/// between steps, and this protocol exists to make "between steps" a place
/// that actually exists.
///
/// ## Why a state machine and not a closure
///
/// A scoped `withPreemption { yield() }` would guarantee the region is
/// entered and left properly, and guarantee nothing about the point the
/// window opens at: nothing stops a caller yielding halfway through
/// relinking a list, with a node pointing at a freed frame, which is exactly
/// the state an interrupt must never see. Cutting the operation into steps
/// moves the pause point *between* two calls to `step()`, so there is no
/// "middle" left to pause in. That structural guarantee is the whole design,
/// which is why there is no yield primitive a step could reach for.
///
/// ## What a step owes
///
/// On return from `step()` the operation's own invariants must hold as if it
/// had finished: no half-linked list, no descriptor pointing at a frame
/// already returned to the allocator, no TLB entry outliving its translation.
/// A step is free to be as large as it needs to be to promise that. It should
/// be small enough that the batch between two checkpoints stays well inside
/// the budget in `CheckpointPolicy`, and no smaller: the cost of the
/// machinery is paid per checkpoint, not per step.
///
/// ## Shape
///
/// Static-only dispatch, like `Loggable`, and for the same reason: the driver
/// is generic over the concrete type so `step()` is a direct call and the
/// whole loop specializes. `any ResumableOperation` would put `step()` behind
/// a witness table and add the kernel's first existential; there are none
/// today and there must not be one here.
///
/// `Failure` may be `Never`, in which case `step()` is written as a plain
/// non-throwing method and `Preemption.run` needs no `try`.
public protocol ResumableOperation {

    /// What a step can fail with. `Never` for operations that cannot.
    associatedtype Failure: Error

    /// Advances the operation by one indivisible unit of work.
    mutating func step() throws(Failure) -> Progress
}
