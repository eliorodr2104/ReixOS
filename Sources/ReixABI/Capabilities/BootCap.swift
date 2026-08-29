//
//  BootCap.swift
//  ReixOS
//

public enum BootCap: UInt32 {
    case parentEndpoint      = 0
    case console             = 1
    case nameServer          = 2
    case spawn               = 3
    case device              = 4
    case nameServerRegistrar = 5
    case profiler            = 6
    case interrupt           = 7

    /// The terminal TextSurface endpoint, not a hardware authority.
    case terminal            = 8

    /// The virtio bus, from which a bus process carves the window and the line
    /// of each transport it finds occupied.
    case virtioBus           = 9

    /// The container this process may see of the disk.
    ///
    /// Not ambient and never inherited: a process arrives with one only because
    /// whoever started it decided to hand one over, and what it hands over may
    /// be narrower than what it holds itself. A process with nothing in this
    /// slot has no view of the disk at all, which is the default.
    case container           = 10

    /// A second, narrower view of the disk: one file or one folder somebody
    /// else owns and chose to hand over, usually read-only.
    ///
    /// Separate from `container` because the two are not the same thing. That
    /// one is where a process lives; this one is a piece of somewhere else it
    /// was let into, and a process may have the second without the first.
    case shared              = 11

    /// The right to set the machine's clock. Reading it needs nothing.
    case clock               = 12

    /// The right to stop the machine.
    case power               = 13

    /// The disk, sector by sector.
    ///
    /// Handed over and never looked up: the block server publishes no name, so
    /// the only way to reach the disk is to have been given this. Exactly one
    /// process gets it unbadged, and that one can claim the volume and write
    /// it; anything else that gets it gets a read-only view, which is a
    /// different capability rather than the same one used politely.
    case block               = 14

    /// A separate, non-delegable authority for interaction profile marks.
    case profileMarker       = 15

    /// The badged InputServer source capability held by a producer.
    case inputSource         = 16

    /// The badged InputServer consumer capability held by a presentation client.
    case inputConsumer       = 17

    /// The badged InputServer focus capability held only by the session manager.
    case inputFocus          = 18

    /// Role-badged SerialServer endpoints, never raw UART authority.
    case serialReader        = 19
    case serialWriter        = 20
}
