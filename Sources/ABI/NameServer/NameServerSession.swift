//
//  NameServerSession.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

/// What a capability on the Name Server is for.
///
/// Lookup is the unbadged one: anybody handed the endpoint may ask for a name,
/// which is the whole point of there being names. Publishing is not, and a badge
/// is how the kernel says so on every request without the server having to trust
/// a word in the message.
///
/// A registrar badge names **the one service its holder may publish**. It used to
/// be a single constant meaning "may register", so any process that had been
/// given one could publish any name and quietly replace whatever was already
/// there - which during boot is one compromised service standing in for another
/// for the rest of the machine's life.
///
/// Which service a process may publish is therefore not the process's own
/// declaration. It is decided by whoever mints the capability, which is init, and
/// it is decided once.
public enum NameServerSession {

    /// The half-word that says this is a Name Server badge at all. "NS", so a
    /// badge is recognisable in a register dump.
    ///
    /// Matched over the whole sixty-four bits a session now carries, with the top
    /// half required to be zero. A badge that used the width the wire allows would
    /// otherwise be read as one of these by the low half alone.
    private static let tag : UInt64 = 0x4E53_0000
    private static let mask: UInt64 = 0xFFFF_FFFF_FFFF_0000

    /// The badge for a capability that may publish `service`, and nothing else.
    ///
    /// The service is stored plus one because zero is what the kernel calls no
    /// badge at all, and the first service is number zero.
    public static func registrar(for service: Services) -> UInt64 {
        Self.tag | UInt64(service.rawValue &+ 1)
    }

    /// The service a badge may publish, or `nil` when it may publish nothing.
    public static func service(of session: UInt64) -> Services? {
        guard session & Self.mask == Self.tag else { return nil }

        let value = session & ~Self.mask
        guard value > 0 else { return nil }

        return Services(rawValue: UInt32(truncatingIfNeeded: value) - 1)
    }
}
