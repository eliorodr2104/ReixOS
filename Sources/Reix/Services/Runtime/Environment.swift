//
//  Environment.swift
//  ReixOS
//
//

import ReixABI

public struct Environment {

    private var slots: InlineArray<21, UInt32?>

    public var parentEndpoint: UInt32? { handle(.parentEndpoint) }
    public var console       : UInt32? { handle(.console) }
    public var nameServer    : UInt32? { handle(.nameServer) }
    public var spawn         : UInt32? { handle(.spawn) }
    public var device        : UInt32? { handle(.device) }
    public var profiler      : UInt32? { handle(.profiler) }
    public var profileMarker : UInt32? { handle(.profileMarker) }

    /// The interrupt lines this process may wait on, if its spawner granted
    /// any. One handle names a whole set: see `irqWait`.
    public var interrupt: UInt32? { handle(.interrupt) }

    /// The terminal this process reads lines from, if it was given one.
    public var terminal     : UInt32? { handle(.terminal) }
    public var inputSource  : UInt32? { handle(.inputSource) }
    public var inputConsumer: UInt32? { handle(.inputConsumer) }
    public var inputFocus   : UInt32? { handle(.inputFocus) }
    public var serialReader : UInt32? { handle(.serialReader) }
    public var serialWriter : UInt32? { handle(.serialWriter) }

    /// The virtio bus, for the process that probes it and hands out what it
    /// finds. Not a window and not a line: the right to carve one.
    public var virtioBus: UInt32? { handle(.virtioBus) }

    /// The container of the disk this process may see, if it was given one.
    ///
    /// `nil` is the normal answer. A view of the disk is something a parent
    /// decides to pass down, and a process that was passed none cannot look one
    /// up: the file system publishes no name.
    public var container: UInt32? { handle(.container) }

    /// A piece of somebody else's container this process was let into.
    public var shared: UInt32? { handle(.shared) }

    /// The disk this process may reach, if it was handed one.
    ///
    /// `nil` for everybody but the file system and whoever was given a
    /// read-only view for looking. Which of the two this is cannot be read off
    /// the handle here: it is the badge the server sees, and the server is what
    /// enforces it.
    public var block: UInt32? { handle(.block) }

    /// The Name Server capability this process may *register* through, if its
    /// spawner granted it one. `nameServer` resolves names for everybody; this
    /// one is the badged capability that also publishes them.
    public var nameServerRegistrar: UInt32? { handle(.nameServerRegistrar) }


    private init(slots: InlineArray<21, UInt32?>) {
        self.slots = slots
    }

    public init(
        console      : UInt32?,
        nameServer   : UInt32?,
        spawn        : UInt32?,
        device       : UInt32? = nil,
        profiler     : UInt32? = nil,
        profileMarker: UInt32? = nil,
        serialReader : UInt32? = nil,
        serialWriter : UInt32? = nil
    ) {

        self.slots = InlineArray<21, UInt32?>(repeating: nil)

        self.slots[Int(BootCap.console.rawValue)]       = console
        self.slots[Int(BootCap.nameServer.rawValue)]    = nameServer
        self.slots[Int(BootCap.spawn.rawValue)]         = spawn
        self.slots[Int(BootCap.device.rawValue)]        = device
        self.slots[Int(BootCap.profiler.rawValue)]      = profiler
        self.slots[Int(BootCap.profileMarker.rawValue)] = profileMarker
        self.slots[Int(BootCap.serialReader.rawValue)]  = serialReader
        self.slots[Int(BootCap.serialWriter.rawValue)]  = serialWriter

    }

    public static func boot() -> Environment {
        var slots = InlineArray<21, UInt32?>(repeating: nil)

        for i in 0..<slots.count {
            let handle = UInt32(i)
            if capExists(handle) { slots[i] = handle }
        }

        return Environment(slots: slots)
    }

    @inline(__always)
    public func handle(_ cap: BootCap) -> UInt32? {
        guard Int(cap.rawValue) < slots.count else { return nil }
        return slots[Int(cap.rawValue)]
    }

}
