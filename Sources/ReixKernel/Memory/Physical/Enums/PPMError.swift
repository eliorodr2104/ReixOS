//
//  PPMError.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/04/2026.
//

public enum PPMError: KernelFatal {
    case allocationFailed       (reason  : AllocatorError)
    case metadataInconsistency
    case invalidFlags
    case protectedMemoryViolation
    case initRamError
    case invalidRefCount        (_ count : Int)
    case pageOrderMismatch      (expected: UInt8, provided: UInt8)

    /// A per-address operation was handed a frame that is not the first of its
    /// block. The offending address is logged where it is detected, so no payload
    /// is carried here.
    case frameNotBlockHead

    /// Every case is a plain literal, and `.allocationFailed` spells the
    /// reason out instead of composing it.
    ///
    /// That difference decides whether this property works at the only
    /// moment it matters. `.allocationFailed` is
    /// raised when memory has run out, `Kernel.internalPanic` asks for this
    /// description to say so, and the concatenation that used to be here
    /// asked the exhausted allocator for one more buffer. `swift_allocObject`
    /// force-unwraps that result, so the kernel died on a nil unwrap while
    /// reporting the fault, and the real diagnosis never reached the console.
    /// The return type is what closes that door: `StaticString` has no `+`, so
    /// a future case cannot reintroduce the concatenation by accident.
    ///
    /// The nested reason is worth keeping, so it is enumerated rather than
    /// interpolated. Cases added to `AllocatorError` must be added here too;
    /// the compiler enforces that, which is why the inner `switch` has no
    /// `default`.
    public var description: StaticString {
        switch self {
            case .allocationFailed(let reason):
                switch reason {
                    case .bytesNotValid      : "PPM Error: allocation failed (invalid byte size requested)."
                    case .fullMemory         : "PPM Error: allocation failed (memory is full)."
                    case .addressInvalid     : "PPM Error: allocation failed (address is out of bounds)."
                    case .addressRangeInvalid: "PPM Error: allocation failed (invalid address range)."
                    case .pageOrderInvalid   : "PPM Error: allocation failed (invalid page order)."
                    case .doubleFreeInvalid  : "PPM Error: allocation failed (double free)."
                }

            case .metadataInconsistency:
                "PPM Error: frame metadata is inconsistent or corrupted."

            case .invalidFlags:
                "PPM Error: invalid page flags detected in metadata."

            case .protectedMemoryViolation:
                "PPM Error: memory protection violation, tried to free a reserved or kernel page."

            case .initRamError:
                "PPM Error: RAM initialization failed (invalid DTB info)."

            case .invalidRefCount:
                "PPM Error: invalid reference count, tried to free an already unreferenced page."

            case .pageOrderMismatch:
                "PPM Error: page order mismatch between metadata and provided page."

            case .frameNotBlockHead:
                "PPM Error: frame is inside a multi-page block, not its head."
        }
    }
}
