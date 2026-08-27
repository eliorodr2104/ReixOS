//
//  VirtioCapacity.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// How big a device says it is, once it has said the same thing twice.
///
/// Sixty-four bits across two thirty-two bit registers, and a legacy mmio
/// transport has no generation counter to say the two halves came from the same
/// moment. A device changing its size between the two reads hands back a number
/// that was never true, and that number becomes the bound every request is
/// checked against.
///
/// So no single reading is believed. Reading again and comparing is what legacy
/// leaves available, and the rule is arithmetic over a sequence of readings,
/// which is why it lives here rather than inside the driver: a device that
/// answers differently every time can be handed to this on a host.
public enum VirtioCapacity {

    /// How many times to ask before giving up.
    ///
    /// Four, so a device that changes size once still settles. One that changes
    /// on every read is a device this driver is about to stop believing anyway,
    /// and the old code's answer there was to use the last reading - a number it
    /// had just watched be wrong.
    public static let attempts = 4

    /// The size two consecutive readings agree on, or nil.
    ///
    /// Zero is refused rather than retried, and refused even when it is stable:
    /// a device with no sectors is a device nothing can be asked of, so agreeing
    /// on nothing is not an agreement worth having.
    public static func settled(_ read: () -> UInt64) -> UInt64? {

        var previous: UInt64? = nil

        for _ in 0..<attempts {
            let seen = read()

            if let previous, previous == seen {
                return seen == 0 ? nil : seen
            }

            previous = seen
        }

        return nil
    }
}
