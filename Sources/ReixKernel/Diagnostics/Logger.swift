//
//  Loggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

public struct Logger<Driver: SerialDriver> {
    let driver: Driver


    @_transparent
    func kprint() {
        driver.write(10)
    }

    @_transparent
    func kputc(_ val: UInt8) {
        driver.write(val)
    }


    // MARK: - Streaming primitives (no trailing newline)

    @_transparent
    func writeStatic(_ s: StaticString) { driver.writeString(s) }

    @_transparent
    func writeString(_ s: String) { driver.writeString(s) }

    @_transparent
    func writeDec(_ v: UInt64) { printDec64(v) }

    @_transparent
    func writeHex(_ v: UInt64, uppercase: Bool) { printHex64(v, uppercase: uppercase) }


    @_transparent
    private func printHex64(_ val: UInt64, uppercase: Bool) {
        if val == 0 {
            driver.write(48) // '0'
            return
        }

        let alpha : UInt8 = uppercase ? 55 : 87 // 'A'-10 / 'a'-10
        var started       = false
        var shift         = 60

        while shift >= 0 {
            let nibble = Int((val >> UInt64(shift)) & 0xF)
            if nibble != 0 { started = true }
            if started {
                driver.write(nibble < 10 ? UInt8(48 + nibble) : alpha &+ UInt8(nibble))
            }
            shift -= 4
        }
    }


    @_transparent
    private func printDec64(_ val: UInt64) {
        if val == 0 {
            driver.write(48)
            return
        }

        var n = val
        var divisor: UInt64 = 1
        var temp = n

        while temp >= 10 {
            temp /= 10
            divisor *= 10
        }

        while divisor > 0 {
            let digit = n / divisor
            driver.write(UInt8(48 + digit))
            n %= divisor
            divisor /= 10
        }
    }
}
