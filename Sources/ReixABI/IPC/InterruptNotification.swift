//
//  InterruptNotification.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// A device speaking on an endpoint.
///
/// A driver that has to wait for a request *and* for its device has one place to
/// wait, and this is what arrives from the second of the two. It is a message
/// shape and not a protocol: nobody sends one, the kernel writes it into a
/// `receive` that was going to park.
///
/// Why it exists. An interrupt used to be collected only by `irqWait`, which
/// parks the caller on the line, and a request only by `receive`, which parks it
/// on an endpoint. A process is in one place at a time, so a driver could wait
/// for work or wait for its disk and never both - which is exactly the reason
/// nothing could keep more than one request in flight, however many descriptors
/// the queue had.
///
/// The event still lives where it always did, in the interrupt set's `pending`
/// bits, so a line that fires with nobody listening is not lost. Binding the set
/// to an endpoint only adds a way to be *woken*, and a `receive` that finds bits
/// already set answers with them instead of parking.
public enum InterruptNotification {

    /// The label the kernel stamps on one.
    ///
    /// High, and reserved. Every protocol in this system numbers its operations
    /// from zero, so nothing can collide with this by accident, and a server
    /// that has never heard of interrupts sees a label it does not recognise and
    /// ignores it - which is what the service loop already does with any label
    /// it cannot name.
    public static let label: UInt32 = 0xFFFF_FF01

    /// The identity a delivered message carries when it came from no process.
    ///
    /// Process identities start at one, so this is a value no sender can ever
    /// have. See `IPCDelivery` and `ProcessManager.identityCounter`.
    public static let kernelIdentity: UInt32 = 0

    /// Whether a received message *looks* like one of these.
    ///
    /// The label and nothing else, which is not enough to act on: see
    /// `fromKernel`.
    public static func names(_ tag: MessageTag) -> Bool {
        tag.label == Self.label
    }

    /// Whether a delivered message is one of these and came from the kernel.
    ///
    /// The label on its own is a claim anybody may make. A process holding a
    /// capability to a driver's endpoint can send a message with any label it
    /// likes, so a driver that acted on the label alone would read and write the
    /// transport's registers and acknowledge an interrupt line on demand, for
    /// whoever could reach it - and on a shared line, acknowledge somebody
    /// else's device.
    ///
    /// The identity is what cannot be forged. The kernel writes it out of the
    /// sender's own control block and writes zero when there was no sender. The
    /// session and the grant are checked too, because the kernel writes neither
    /// and a message carrying either is not one it wrote.
    public static func fromKernel(
        tag       : MessageTag,
        identity  : UInt32,
        session   : UInt64,
        grantedCap: UInt32?
    ) -> Bool {

        names(tag)
            && identity == Self.kernelIdentity
            && session == 0
            && grantedCap == nil
    }

    /// The lines that fired, as bits over the holder's own line list - the same
    /// answer `irqWait` gives, in the same shape.
    public static func lines(of message: Message) -> UInt32 {
        message.words[0]
    }
}
