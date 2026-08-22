//
//  StackUsage.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/08/2026.
//

/// How much of each kernel stack has ever been used.
///
/// `boot.S` fills both stacks with `poison` before a single frame exists on
/// them, so the lowest address that no longer holds that word is the lowest
/// address ever written. Nothing maintains a counter: the memory *is* the
/// measurement, and reading it costs one pass and no bookkeeping.
///
/// What it reports is what was **written**, which is a lower bound on what was
/// **reserved**: a prologue can move SP down by more than the body ever stores
/// into, and that padding leaves the poison intact. A size decision therefore
/// wants margin on top of these numbers, never equality with them.
///
/// The userland side of the same question needs none of this. A user stack is
/// a `.growDown` VMA that only ever gained a page because a fault demanded it,
/// so its extent already records its high-water mark exactly. See
/// `VMAManager.stackPages`.
enum StackUsage {

    /// `REIXSTK!`. Chosen because no pointer, length, tag or zeroed struct can
    /// hold it, and because it is legible when it does show up in a dump.
    static let poison: UInt64 = 0x5245_4958_5354_4B21

    /// Bytes of `.stack` ever written, against `kernelStackCapacity`.
    static var kernelStack: UInt64 {
        used(from: kernelSpan.from, to: kernelSpan.to)
    }

    /// Bytes of `.exception_stack` ever written, against its own capacity.
    ///
    /// Zero on every healthy boot: that stack carries the panic report and
    /// nothing else, so a run that never faulted has genuinely never touched
    /// it. Only a run that panicked says anything about its size.
    static var exceptionStack: UInt64 {
        used(from: exceptionSpan.from, to: exceptionSpan.to)
    }

    /// Size of `.stack`, read from the linker rather than restated here.
    static var kernelStackCapacity: UInt64 {
        kernelSpan.to &- kernelSpan.from
    }

    /// Size of `.exception_stack`, likewise.
    static var exceptionStackCapacity: UInt64 {
        exceptionSpan.to &- exceptionSpan.from
    }


    /// Distance from the first non-poison word up to `top`.
    ///
    /// Scans upward from the bottom, which is the direction that finds the
    /// deepest point first: the stack grows down, so the lowest touched word
    /// is the high-water mark. A fully intact range answers zero, and a fully
    /// consumed one answers its whole size, which is the case the guard page
    /// below `.stack` is there to catch before it can ever be reported.
    ///
    /// Not private, and not folded into the accessors above: this is the part
    /// worth a test, and on the host it is the only part that can have one.
    static func used(from bottom: UInt64, to top: UInt64) -> UInt64 {
        guard top > bottom,
              bottom & 7 == 0,
              let base = UnsafeRawPointer(bitPattern: UInt(bottom)) else { return 0 }

        let size   = Int(top - bottom)
        var offset = 0

        while offset + 8 <= size {
            guard base.load(fromByteOffset: offset, as: UInt64.self) == poison else {
                return UInt64(size - offset)
            }

            offset += 8
        }

        return 0
    }


    /// The `.stack` span, as the linker placed it.
    ///
    /// Seamed exactly like `PPMBackend.physicalOffset`: `hasFeature(Embedded)`
    /// is on only for the machine build. The host's stand-ins for these four
    /// symbols are four unrelated bytes in `KernelHostShims.c` and not two
    /// regions, so there is no span to scan there and every figure reads zero
    /// rather than dereferencing whatever lies between two globals.
    private static var kernelSpan: (from: UInt64, to: UInt64) {
        #if hasFeature(Embedded)
            (
                getOfaddressWithSymbol(of: &__stack_bottom),
                getOfaddressWithSymbol(of: &stack_top)
            )
        #else
            (0, 0)
        #endif
    }

    /// The `.exception_stack` span, likewise.
    private static var exceptionSpan: (from: UInt64, to: UInt64) {
        #if hasFeature(Embedded)
            (
                getOfaddressWithSymbol(of: &__exception_stack_bottom),
                getOfaddressWithSymbol(of: &__exception_stack_top)
            )
        #else
            (0, 0)
        #endif
    }
}
