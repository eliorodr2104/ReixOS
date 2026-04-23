//
//  Loggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
//

private let uartManager = UARTQemu()

enum Mode {
    case hex
    case dec
    case bin
    case oct
}

// Tabella di conversione veloce per Hex
private let HEX_DIGITS: [UInt8] = [
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, // 0-9
    65, 66, 67, 68, 69, 70                  // A-F
]

// MARK: - C Bridge (sprintf fixed params)
@_extern(c, "format1")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64) -> UnsafePointer<Int8>

@_extern(c, "format2")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64, _ b: UInt64) -> UnsafePointer<Int8>

@_extern(c, "format3")
func sprintf(_ fmt: UnsafePointer<Int8>, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> UnsafePointer<Int8>

// MARK: - Helper Interni

@_transparent
private func printCString(_ ptr: UnsafePointer<Int8>?) {
    guard let p = ptr else { return }
    var current = p
    while current.pointee != 0 {
        uartManager.write(UInt8(current.pointee))
        current += 1
    }
}

// MARK: - KPRINTF (Senza Nuova Linea)

@_transparent
func kprintf(_ val: String) {
    for byte in val.utf8 {
        uartManager.write(byte)
    }
}

// Overload per UInt64 (principale)
@_transparent
func kprintf(_ fmt: String, _ a: UInt64) {
    fmt.withCString { ptr in printCString(sprintf(ptr, a)) }
}

@_transparent
func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64) {
    fmt.withCString { ptr in printCString(sprintf(ptr, a, b)) }
}

@_transparent
func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64, _ c: UInt64) {
    fmt.withCString { ptr in printCString(sprintf(ptr, a, b, c)) }
}

// Overload per Int32 (comodità)
@_transparent
func kprintf(_ fmt: String, _ a: Int32) {
    kprintf(fmt, UInt64(a))
}

@_transparent
func kprintf(_ fmt: String, _ a: Int32, _ b: Int32) {
    kprintf(fmt, UInt64(a), UInt64(b))
}

// MARK: - KPRINT (Con Nuova Linea)

@_transparent
func kprint(_ val: String) {
    kprintf(val)
    uartManager.write(10)
}

@_transparent
func kprint(_ fmt: String, _ a: UInt64) {
    kprintf(fmt, a)
    uartManager.write(10)
}

@_transparent
func kprint(_ fmt: String, _ a: Int32) {
    kprintf(fmt, UInt64(a))
    uartManager.write(10)
}

@_transparent
func kprint() {
    uartManager.write(10)
}

// MARK: - Gestione Numeri e Indirizzi (Manuale)

/// Stampa un indirizzo di memoria in formato 0x0000000000000000 (fixed width)
@_transparent
func kprintAddr(_ addr: UInt64) {
    kprintf("0x")
    for i in (0...15).reversed() {
        let shift = UInt64(i * 4)
        let nibble = Int((addr >> shift) & 0xF)
        uartManager.write(HEX_DIGITS[nibble])
    }
    uartManager.write(10)
}

@_transparent
func kprint(_ val: UInt64, mode: Mode = .dec) {
    kprintf(val, mode: mode)
    uartManager.write(10)
}

@_transparent
func kprintf(_ val: UInt64, mode: Mode = .dec) {
    switch mode {
        case .hex:
            printHex64(val, prefix: true, padded: false)
            
        case .dec:
            printDec64(val)
            
        default:
            return
    }
}

// MARK: - Implementazioni Low-Level (Senza C)

@_transparent
private func printHex64(_ val: UInt64, prefix: Bool, padded: Bool) {
    if prefix {
        uartManager.write(48) // '0'
        uartManager.write(120) // 'x'
    }
    
    if val == 0 {
        uartManager.write(48)
        return
    }
    
    var started = false
    for i in (0...15).reversed() {
        let shift  = UInt64(i * 4)
        let nibble = Int((val >> shift) & 0xF)
        
        if nibble != 0 || started || padded || i == 0 {
            uartManager.write(HEX_DIGITS[nibble])
            if nibble != 0 { started = true }
        }
    }
}

@_transparent
private func printDec64(_ val: UInt64) {
    if val == 0 {
        uartManager.write(48)
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
        uartManager.write(HEX_DIGITS[Int(digit)])
        n %= divisor
        divisor /= 10
    }
}
