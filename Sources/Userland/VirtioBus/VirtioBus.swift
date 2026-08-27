//
//  VirtioBus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// Walks the virtio transports and says what is on them.
///
/// The one process that reads a device id, which is what keeps that knowledge
/// out of the kernel. The machine's own description says where the bus is and
/// how wide; it cannot say which slots are occupied, because virtio-mmio is
/// found by reading and not by being described.
///
/// It holds the bus and carves from it: a window per slot, four registers read,
/// then the window given back unless the slot held something worth keeping. The
/// giving back is not tidiness. A capability table has sixteen entries and this
/// machine has thirty-two transports.
public struct VirtioBus {

    /// Register offsets, from the virtio-mmio layout. The only three this needs.
    private enum Register {
        static let magic    : UInt64 = 0x00
        static let version  : UInt64 = 0x04
        static let deviceID : UInt64 = 0x08
    }

    /// "virt", little endian: what every transport answers, occupied or not.
    private static let magicValue: UInt64 = 0x7472_6976

    /// What a device id means, for the ones this system has a name for.
    public static func name(of deviceID: UInt64) -> StaticString {
        switch deviceID {
            case 1 : "network"
            case 2 : "block"
            case 3 : "console"
            case 4 : "entropy"
            case 16: "gpu"
            case 18: "input"
            default: "unknown"
        }
    }


    /// One occupied transport, and the window that reached it.
    public struct Transport {
        public let slot    : UInt32
        public let window  : UInt32
        public let deviceID: UInt64
        public let version : UInt64
    }


    /// Reads every slot on `bus` and hands each occupied one to `keep`.
    ///
    /// `keep` answers whether the window is wanted. Answering false gives it
    /// back at once, which is what lets a walk of thirty-two slots run inside a
    /// table of sixteen handles. Answering true makes the caller the owner of
    /// that handle, and the one who has to drop it.
    ///
    /// There is no slot count to pass. The walk stops when the bus refuses to
    /// carve the next window, which is the bus saying where it ends.
    ///
    /// Slots are numbered, not addressed. This used to multiply the slot by a
    /// window width and ask for that offset, which meant this process was
    /// computing where a transport sits - a fact it does not have and the kernel
    /// does. Now it counts, and the same number names the line further on.
    public static func walk(bus: UInt32, _ keep: (Transport) -> Bool) {

        var slot: UInt32 = 0

        while true {
            let window = busDeriveDevice(handle: bus, index: slot)
            guard window != UInt32.max else { return }

            let device = deviceRead(handle: window, offset: Register.deviceID)
            var wanted = false

            if deviceRead(handle: window, offset: Register.magic) == Self.magicValue,
               device != 0, device != UInt64.max {

                wanted = keep(Transport(
                    slot    : slot,
                    window  : window,
                    deviceID: device,
                    version : deviceRead(handle: window, offset: Register.version)
                ))
            }

            if !wanted { _ = capDrop(window) }

            slot &+= 1
        }
    }
}
