//
//  Capability.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

import ReixABI

/// One slot of a process's capability table: what it names, which conversation
/// it belongs to, and what its holder may do with it.
///
/// The target is stored decomposed into two words and a tag rather than as a
/// `CapTarget` value. The enum spends one byte past the sixteen the device
/// window fills, and that byte cost the struct a whole alignment hole: 25 bytes
/// living in a 32 byte stride, sixteen times over in every `CapsTable`. Packed
/// it is 22 bytes in a 24 byte stride, which is what keeps `ProcessMetadata`
/// inside the 512 byte slab bucket instead of the 1024 byte one.
///
/// Ordering matters only in that the two byte-wide fields have to stay on the
/// same side of `badge`: split across it, its 4 byte alignment reopens the hole
/// and the stride goes back to 32. Whether it leads them or trails them moves
/// the measured size, 22 against 24, and not the stride the table pays.
public struct Capability: Equatable {

    /// Which `CapTarget` case `word` and `extent` spell out.
    private enum Kind: UInt8 {
        case endpoint
        case shared
        case dma
        case device
        case interrupt
        case profileControl
    }

    /// Address of the endpoint or shared region this names, or the base of the
    /// device window. Zero for `profileControl`, which has no backing object.
    private var word  : UInt64

    /// Byte width of the device window, and zero for every other kind, so that
    /// two capabilities compare equal exactly when their targets do.
    private var extent: UInt64

    /// Session token.
    ///
    /// `transferCapability`/`injectCapability` copy this value unchanged, so it
    /// says *which conversation* a message belongs to and can say nothing about
    /// who sent it: the sender's principal is `Process.identity` and travels in
    /// the other half of `x6`.
    ///
    /// `0` means "no session", and is set-once-from-zero through `CapsTable.mint`:
    /// a cap already bound to a session can never be rebound, or its holder could
    /// recycle a stale session into a server's per-client state.
    public var badge : Badge
    public var rights: CapRights

    private var kind : Kind


    public init(
        target: CapTarget,
        badge : Badge,
        rights: CapRights
    ) {
        self.badge  = badge
        self.rights = rights

        switch target {
            case .endpoint(let endpoint):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(endpoint)))
                extent = 0
                kind   = .endpoint

            case .shared(let region):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(region)))
                extent = 0
                kind   = .shared

            case .dma(let region):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(region)))
                extent = 0
                kind   = .dma

            case .device(let region):
                word   = region.address
                extent = region.size
                kind   = .device

            case .interrupt(let set):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(set)))
                extent = 0
                kind   = .interrupt

            case .profileControl:
                word   = 0
                extent = 0
                kind   = .profileControl
        }
    }


    /// The stored words read back as the case they were built from.
    ///
    /// The two object kinds unwrap unchecked because `init` is the only writer
    /// of `word`, and it only ever stores the address of a live allocation
    /// there: a nil here would mean the table itself is corrupt.
    @inline(__always)
    public var target: CapTarget {
        switch kind {
            case .endpoint:
                .endpoint(
                    UnsafeMutablePointer<Endpoint>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .shared:
                .shared(
                    UnsafeMutablePointer<SharedRegion>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .dma:
                .dma(
                    UnsafeMutablePointer<SharedRegion>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .device:
                .device(DeviceRegion(address: word, size: extent))

            case .interrupt:
                .interrupt(
                    UnsafeMutablePointer<InterruptSet>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .profileControl:
                .profileControl
        }
    }
}
