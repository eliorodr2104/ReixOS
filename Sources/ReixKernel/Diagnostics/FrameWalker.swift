//
//  FrameWalker.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 04/08/2026.
//

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
        let stackLow  = getOfaddressWithSymbol(of: &__stack_bottom)
        let stackHigh = getOfaddressWithSymbol(of: &stack_top)

        if containsRecord(fp, low: stackLow, high: stackHigh) {
            walk(from: fp, stackLow: stackLow, stackHigh: stackHigh, limit: limit, visit)
            return
        }

        let (virtualStackLow, lowOverflow) = stackLow.addingReportingOverflow(
            VirtualMemoryManager.physicalOffset
        )
        let (virtualStackHigh, highOverflow) = stackHigh.addingReportingOverflow(
            VirtualMemoryManager.physicalOffset
        )

        if !lowOverflow, !highOverflow,
           containsRecord(fp, low: virtualStackLow, high: virtualStackHigh) {
            walk(
                from: fp,
                stackLow: virtualStackLow,
                stackHigh: virtualStackHigh,
                limit: limit,
                visit
            )
            return
        }

        let exceptionLow = getOfaddressWithSymbol(of: &__exception_stack_bottom)
        let exceptionHigh = getOfaddressWithSymbol(of: &__exception_stack_top)

        if containsRecord(fp, low: exceptionLow, high: exceptionHigh) {
            walk(from: fp, stackLow: exceptionLow, stackHigh: exceptionHigh, limit: limit, visit)
        }
    }


    @inline(__always)
    static func walk(
        from fp       : UInt64,
        stackLow      : UInt64,
        stackHigh     : UInt64,
        limit         : Int,
        _        visit: (UInt64) -> Bool
    ) {
        var framePointer = fp
        var visited      = 0

        while visited < limit,
              containsRecord(
                    framePointer,
                    low : stackLow,
                    high: stackHigh
              ) {
            
            let previous      = word(at: framePointer)
            let returnAddress = word(at: framePointer + 8)

            guard returnAddress != 0, visit(returnAddress) else { break }

            visited &+= 1

            guard previous > framePointer else { break }

            framePointer = previous
        }
    }


    @inline(__always)
    static func isPlausible(_ framePointer: UInt64) -> Bool {
        framePointer != 0 && framePointer & 0xF == 0
    }


    @inline(__always)
    private static func containsRecord(
        _ framePointer: UInt64,
          low         : UInt64,
          high        : UInt64
    ) -> Bool {
        
        guard low < high, framePointer >= low,
              isPlausible(framePointer) else { return false }
        
        let (end, overflow) = framePointer.addingReportingOverflow(16)
        return !overflow && end <= high
    }


    @inline(__always)
    private static func word(at address: UInt64) -> UInt64 {
        UnsafePointer<UInt64>(bitPattern: UInt(address))?.pointee ?? 0
    }
}
