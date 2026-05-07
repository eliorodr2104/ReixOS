//
//  Loggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

public struct Logger<Driver: SerialDriver> {
    let driver: Driver
    
    private let HEX_DIGITS: [UInt8] = [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 65, 66, 67, 68, 69, 70]
    
    
    @_transparent
    func kprintf(_ val: String) {
        driver.writeString(val)
    }
    
    
    func kprintf(_ fmt: String, _ a: UInt64) {
        fmt.withCString { ptr in printCString(sprintf(ptr, a)) }
        driver.write(10)
    }
    
    func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64) {
        fmt.withCString { ptr in printCString(sprintf(ptr, a, b)) }
        driver.write(10)
    }
    
    func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64, _ c: UInt64) {
        fmt.withCString { ptr in printCString(sprintf(ptr, a, b, c)) }
        driver.write(10)
    }
    
    func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) {
        fmt.withCString { ptr in printCString(sprintf(ptr, a, b, c, d)) }
        driver.write(10)
    }
    
    
    // Kprintf Overload Int32
    @_transparent
    func kprintf(_ fmt: String, _ a: Int32) {
        kprintf(fmt, UInt64(a))
    }
    
    @_transparent
    func kprintf(_ fmt: String, _ a: Int32, _ b: Int32) {
        kprintf(fmt, UInt64(a), UInt64(b))
    }
    
    @_transparent
    func kprintf(_ fmt: String, _ a: Int32, _ b: Int32, _ c: Int32) {
        kprintf(fmt, UInt64(a), UInt64(b), UInt64(c))
    }
    
    @_transparent
    func kprintf(_ fmt: String, _ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32) {
        kprintf(fmt, UInt64(a), UInt64(b), UInt64(c), UInt64(d))
    }
    
    
    // MARK: - KPRINT
    
    @_transparent
    func kprint(_ val: String) {
        kprintf(val)
        driver.write(10)
    }
    
    @_transparent
    func kprint() {
        driver.write(10)
    }
    
    @_transparent
    func kprint(_ val: UInt64) {
        printDec64(val)
    }

    @_transparent
    func kputc(_ val: UInt8) {
        driver.write(val)
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
            driver.write(HEX_DIGITS[Int(digit)])
            n %= divisor
            divisor /= 10
        }
    }
    
    
    // MARK: - Helper
    
    @_transparent
    private func printCString(_ ptr: UnsafePointer<Int8>?) {
        guard let p = ptr else { return }
        var current = p
        while current.pointee != 0 {
            driver.write(UInt8(current.pointee))
            current += 1
        }
    }
}
