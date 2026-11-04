//
//  PhysicalPageManager+Diagnosis.swift
//  ReixOS
//

/// What the page manager's books say about a block somebody believes they hold.
///
/// The answer to a refused `free`, read after the refusal: the error says which
/// check failed, this says what the frame actually is, which is what decides
/// whether anything may be done about it. Two bytes, so a region refused by the
/// PPM can carry the reading in its cell.
public enum PhysicalBlockState: Equatable {

    /// A live block head of the order asked about, owned by the allocator and
    /// referenced. The books would take it back, so a refusal came from
    /// somewhere they do not describe: the buddy, or the manager's own count.
    case live

    /// A live block head, but of another order. Freeing it at the order asked
    /// about would hand the buddy a block of the wrong size.
    case orderMismatch(recorded: UInt8)

    /// A frame inside some other block, not the head of one.
    case interior

    /// Nobody holds it: the manager has already given it back to the buddy.
    case free

    /// Withheld at boot, never the allocator's to hand out.
    case reserved

    /// A live head carrying `.kernel`, which the ordinary `free` refuses.
    case kernelOwned

    /// Records that contradict each other: an owned head with no reference, an
    /// extent that does not fit in RAM, or references on a frame nobody owns.
    case damaged

    /// Not a frame these books describe: below or past RAM, not page aligned,
    /// or a manager with no metadata at all.
    case outsideRAM


    /// For a log line, which takes nothing but literals.
    public var description: StaticString {
        switch self {
            case .live         : "a live block of that order"
            case .orderMismatch: "a live block of another order"
            case .interior     : "the inside of another block"
            case .free         : "already free"
            case .reserved     : "a frame withheld at boot"
            case .kernelOwned  : "a kernel block"
            case .damaged      : "records that contradict each other"
            case .outsideRAM   : "not a frame of RAM"
        }
    }
}


extension PhysicalPageManager {

    /// What the books say about the block of `order` at `address`.
    ///
    /// Read only, and that is the point: it runs after a refusal, on books that
    /// may be wrong, and a diagnosis that repaired as it went would destroy the
    /// evidence and could corrupt a neighbour. It reads the head's `FrameInfo`
    /// once, by value, and asks `validatedLiveBlock` the same questions `free`
    /// asks, in the same order, so the two never disagree about a frame.
    ///
    /// The buddy's own bitmap is not consulted: the allocator answers no
    /// read-only question. `.free` is therefore the manager's word, which it
    /// writes only after the buddy has accepted a block.
    public func diagnose(
        _ address: PhysicalAddress,
        order    : UInt8
    ) -> PhysicalBlockState {
        guard let index = frameIndex(for: address),
              let framesMetadata
        else { return .outsideRAM }

        let metadata = framesMetadata[index]

        do {
            _ = try validatedLiveBlock(metadata: metadata, headIndex: index)

        } catch {
            switch error {
                case .frameNotBlockHead       : return .interior
                case .protectedMemoryViolation: return .reserved
                case .frameNotAllocated       : return metadata.refCount == 0 ? .free : .damaged
                default                       : return .damaged
            }
        }

        guard metadata.order == order else {
            return .orderMismatch(recorded: metadata.order)
        }

        guard !metadata.flags.contains(.kernel) else { return .kernelOwned }

        return .live
    }
}
