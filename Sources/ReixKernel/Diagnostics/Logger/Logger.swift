//
//  Loggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

/// The driver-facing half of the logger: bytes in, wire out, no policy.
///
/// Number and record formatting deliberately does *not* live here. It sits
/// in `LogSink`, above the fork between the UART and the log ring, so both
/// destinations render identically from a single implementation.
public struct Logger<Driver: SerialDriver> {
    
    let driver: Driver

    @_transparent
    func kputc(_ val: UInt8) {
        driver.write(val)
    }


    // MARK: - Streaming primitives (no trailing newline)

    @_transparent
    func writeStatic(_ s: StaticString) { driver.writeString(s) }

    @_transparent
    func writeString(_ s: String) { driver.writeString(s) }
}
