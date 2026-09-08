//
//  Serial.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

/// What the kernel does with a serial port, which is write to it.
///
/// There is no `read`. The kernel has no reason to take a byte off the wire:
/// input belongs to SerialServer, which owns the device in userland, and the
/// meaning of those bytes belongs further out still. A protocol that named a
/// read would be an invitation to answer one.
public protocol SerialDriver {
    func write(_ byte: UInt8)
}


extension SerialDriver {

    func writeString(_ s: StaticString) {
        s.withUTF8Buffer { buffer in
            for b in buffer { write(b) }
        }
    }
}
