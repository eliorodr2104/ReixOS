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
/// Ordering matters only in that the narrow fields have to stay together on one
/// side of the eight-byte ones: split across them, the alignment hole reopens and
/// the stride goes back to 32.
///
/// The session went to sixty-four bits and the stride did not, which is the
/// arithmetic worth writing down: eight for the address, eight for the session,
/// four for the window's width, two for the rights and one for the kind is
/// twenty-three in a twenty-four byte stride. Had the window kept its sixty-four
/// bits the stride would be thirty-two, thirty-two slots per table would cost two
/// hundred and fifty-six bytes more, and `ProcessMetadata` would cross out of the
/// 1024 byte slab bucket into the 2048 one - on a machine targeting four
/// megabytes.
public struct Capability: Equatable {

    /// Which `CapTarget` case `word` and `extent` spell out.
    private enum Kind: UInt8 {
        case endpoint
        case shared
        case dma
        case device
        case bus
        case interrupt
        case profileControl
        case clock
        case power
    }

    /// Address of the endpoint or shared region this names, or the base of the
    /// device window. Zero for `profileControl`, which has no backing object.
    private var word  : UInt64

    /// Session token.
    ///
    /// `transferCapability`/`injectCapability` copy this value unchanged, so it
    /// says *which conversation* a message belongs to and can say nothing about
    /// who sent it: the sender's principal is `Process.identity` and travels in
    /// `x7`, in a register of its own.
    ///
    /// `0` means "no session", and is set-once-from-zero through `CapsTable.mint`:
    /// a cap already bound to a session can never be rebound, or its holder could
    /// recycle a stale session into a server's per-client state.
    public var badge : Badge

    /// Byte width of the device window, and zero for every other kind, so that
    /// two capabilities compare equal exactly when their targets do.
    ///
    /// Thirty-two bits, which is what pays for the session being sixty-four, and
    /// declared *after* the wide fields rather than beside `word` for the reason
    /// in the type's own note: the narrow fields have to sit together or the
    /// alignment hole reopens and the stride goes back to 32.
    ///
    /// A window is a device's register block, and the widest this machine has is
    /// a page. Four gigabytes is the bound, and `init` clips rather than wraps: a
    /// window this cannot represent comes back *smaller* than it was asked for,
    /// which refuses more than it should rather than allowing more.
    private var extent: UInt32

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
                extent = region.size > UInt64(UInt32.max)
                    ? UInt32.max
                    : UInt32(region.size)
                kind   = .device

            case .bus(let authority):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(authority)))
                extent = 0
                kind   = .bus

            case .interrupt(let set):
                word   = UInt64(UInt(bitPattern: UnsafeMutableRawPointer(set)))
                extent = 0
                kind   = .interrupt

            case .profileControl:
                word   = 0
                extent = 0
                kind   = .profileControl

            case .clock:
                word   = 0
                extent = 0
                kind   = .clock

            case .power:
                word   = 0
                extent = 0
                kind   = .power
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
                .device(DeviceRegion(address: word, size: UInt64(extent)))

            case .bus:
                .bus(
                    UnsafeMutablePointer<BusAuthority>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .interrupt:
                .interrupt(
                    UnsafeMutablePointer<InterruptSet>(bitPattern: UInt(word)).unsafelyUnwrapped
                )

            case .profileControl:
                .profileControl

            case .clock:
                .clock

            case .power:
                .power
        }
    }
}
