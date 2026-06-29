//
//  Environment.swift
//  ReixOS
//
//  The capabilities a process is born with, read once from its boot slots and
//  handed to the service instead of reached for through a global.
//

import ReixABI

public struct Environment {

    private var slots: InlineArray<8, UInt32?>

    private init(slots: InlineArray<8, UInt32?>) {
        self.slots = slots
    }

    public init(
        console   : UInt32?,
        nameServer: UInt32?,
        spawn     : UInt32?,
        device    : UInt32? = nil
    ) {
        var slots = InlineArray<8, UInt32?>(repeating: nil)
        slots[Int(BootCap.console.rawValue)]    = console
        slots[Int(BootCap.nameServer.rawValue)] = nameServer
        slots[Int(BootCap.spawn.rawValue)]      = spawn
        slots[Int(BootCap.device.rawValue)]     = device
        self.slots = slots
    }

    public static func boot() -> Environment {
        var slots = InlineArray<8, UInt32?>(repeating: nil)

        for i in 0..<slots.count {
            let handle = UInt32(i)
            if capExists(handle) { slots[i] = handle }
        }

        return Environment(slots: slots)
    }

    public func handle(_ cap: BootCap) -> UInt32? {
        guard Int(cap.rawValue) < slots.count else { return nil }
        return slots[Int(cap.rawValue)]
    }

    public var parentEndpoint: UInt32? { handle(.parentEndpoint) }
    public var console       : UInt32? { handle(.console) }
    public var nameServer    : UInt32? { handle(.nameServer) }
    public var spawn         : UInt32? { handle(.spawn) }
    public var device        : UInt32? { handle(.device) }
}
