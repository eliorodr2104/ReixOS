//
//  CapabilityRelease.swift
//  ReixOS
//

/// `RendezvousIPC.releaseCapabilities` for a dying process, one held slot per
/// step, so the interrupt window has somewhere to open inside it.
///
/// It is the last long stretch of a death once the address space is gone:
/// every release can destroy an endpoint, wake the callers parked on it and
/// free a shared region, and a table of them ran masked from the first slot to
/// the last. A step leaves the table and every object it named consistent, one
/// slot fewer, which is all a window needs.
///
/// Each step makes its own short call through `ipc`, rather than the whole loop
/// running inside one mutating call: the timer handler a window lets in reaches
/// the same `RendezvousIPC` to expire deadlines, and must not find it in the
/// middle of an access.
struct CapabilityRelease: ResumableOperation {

    typealias Failure = Never

    private let ipc     : UnsafeMutablePointer<KernelIPC>
    private let metadata: UnsafeMutablePointer<ProcessMetadata>

    /// The next slot to look at.
    private var slot = 0


    init(
        ipc     : UnsafeMutablePointer<KernelIPC>,
        metadata: UnsafeMutablePointer<ProcessMetadata>
    ) {
        self.ipc      = ipc
        self.metadata = metadata
    }


    /// Releases the next held slot. Empty slots are skipped inside the step,
    /// so a window never opens for a slot that cost nothing.
    mutating func step() -> Progress {
        let count = metadata.pointee.capsTable.caps.count

        while slot < count {
            let released = ipc.pointee.releaseSlot(slot, of: metadata)
            slot += 1

            if released { return slot < count ? .more : .done }
        }

        return .done
    }
}
