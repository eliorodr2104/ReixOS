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

    /// The address is outside the complete 4 KiB frames described by the
    /// metadata array, or is not aligned to a frame boundary.
    case invalidFrameAddress    (_ address: PhysicalAddress)

    /// The metadata names a free frame rather than a live block currently
    /// owned by the allocator client. Reserved frames have their own refusal.
    case frameNotAllocated

    /// Retaining would wrap the fixed-width counter back to zero.
    case referenceCountOverflow

    /// The frames are there, and the process asking for them has already been
    /// charged everything its `FrameBudget` allows. Raised before the allocator
    /// is asked, so a refusal costs no allocation and leaves no partial state.
    ///
    /// Reported as out of memory, because that is what it is from the asking
    /// program's side: a legitimate request the machine will not serve it.
    case budgetExceeded


    /// A per-address operation was handed a frame that is not the first of its
    /// block. No payload is needed because the caller already owns the request.
    case frameNotBlockHead

    /// The four refusals of the leaf-descriptor operations in
    /// `VirtualMemoryManager`, one per precondition those operations state.
    ///
    /// They live here and not in an enum of their own because the whole mapping
    /// surface already throws `PPMError`, and every caller of it already routes
    /// a failure the same way. What matters is that each refusal is its own
    /// case: an operation handed an entry in the wrong state must not quietly
    /// become one of the other three, which is exactly what the single writer
    /// these replaced used to do.

    /// `installUserPage` found a valid descriptor. Replacing the frame is
    /// `replaceUserPage`, changing the permissions is `protectUserPage`.
    case pageAlreadyMapped

    /// `protectUserPage` or `replaceUserPage` found no valid descriptor. There
    /// is nothing to change the permissions or the frame of.
    case pageNotMapped

    /// `protectUserPage` was given a memory type other than the one the
    /// descriptor carries. Changing the MAIR index or the shareability of a
    /// valid descriptor needs break-before-make, which a protect does not do.
    case pageAttributesImmutable

    /// `replaceUserPage` was given the frame the descriptor already names.
    /// Breaking a translation to put back what was there is a permission
    /// change at most, so the caller wanted `protectUserPage`.
    case pageReplaceWithoutChange

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

            case .invalidFrameAddress:
                "PPM Error: frame address is outside RAM or is not page aligned."

            case .frameNotAllocated:
                "PPM Error: frame is not a live allocator-owned block."

            case .referenceCountOverflow:
                "PPM Error: frame reference count is saturated."

            case .budgetExceeded:
                "PPM Error: the process has been charged every frame its budget allows."

            case .pageAlreadyMapped:
                "PPM Error: install found a valid descriptor already mapping that page."

            case .pageNotMapped:
                "PPM Error: protect or replace found no valid descriptor for that page."

            case .pageAttributesImmutable:
                "PPM Error: protect cannot change the memory type of a valid descriptor."

            case .pageReplaceWithoutChange:
                "PPM Error: replace was given the frame the descriptor already names."
        }
    }
}
