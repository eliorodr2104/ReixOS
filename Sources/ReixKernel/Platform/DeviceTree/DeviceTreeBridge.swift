//
//  DeviceTreeBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

// Pure-Swift flattened-device-tree parser (replaces the former C `fdt_parser.c`).
// Walks the FDT struct block once, inheriting #address-cells/#size-cells from
// parents, and fills `PlatformInfo` (RAM, UART, GIC, initrd, cpu count, bootargs).
// All multi-byte fields in an FDT are big-endian; the blob is 4-byte aligned, so
// every `UInt32` load lands on a 4-aligned address (safe under -mstrict-align).

private enum FDT {
    static let beginNode: UInt32 = 0x1
    static let endNode  : UInt32 = 0x2
    static let prop     : UInt32 = 0x3
    static let nop      : UInt32 = 0x4
    static let end      : UInt32 = 0x9
    static let maxDepth = 16
    static let magic    : UInt32 = 0xd00dfeed
}

@inline(__always)
private func fdt32(_ base: UnsafeRawPointer, _ off: Int) -> UInt32 {
    base.load(fromByteOffset: off, as: UInt32.self).byteSwapped
}

@inline(__always)
private func bytes(_ base: UnsafeRawPointer, _ off: Int) -> UnsafePointer<UInt8> {
    base.advanced(by: off).assumingMemoryBound(to: UInt8.self)
}

/// Compares a NUL-terminated C string at `a` against the static literal `b`.
@inline(__always)
private func ceq(_ a: UnsafePointer<UInt8>, _ b: StaticString) -> Bool {
    let n  = b.utf8CodeUnitCount
    let bp = b.utf8Start
    var i  = 0
    while i < n {
        let c = a[i]
        if c == 0 || c != bp[i] { return false }
        i += 1
    }
    return a[i] == 0
}

/// Combines `n` consecutive big-endian cells at byte offset `off` into a value.
@inline(__always)
private func readCells(_ base: UnsafeRawPointer, _ off: Int, _ n: UInt32) -> UInt64 {
    var v: UInt64 = 0
    var i = 0
    while i < Int(n) {
        v = (v << 32) | UInt64(fdt32(base, off + i * 4))
        i += 1
    }
    return v
}

func parsePlatformInfo(fdt: UnsafeRawPointer, into out: inout PlatformInfo) -> Int32 {
    out.uart.type     = 0
    out.uart.baseAddr = 0
    out.cpuCount      = 0
    out.initrdStart   = 0
    out.initrdEnd     = 0

    guard fdt32(fdt, 0) == FDT.magic else { return -1 }

    let totalsize   = fdt32(fdt, 4)
    let offStruct   = fdt32(fdt, 8)
    let offStrings  = fdt32(fdt, 12)
    let sizeStrings = fdt32(fdt, 32)
    let sizeStruct  = fdt32(fdt, 36)

    let headerSize: UInt32 = 40
    guard totalsize >= headerSize else { return -2 }
    guard offStruct >= headerSize, offStruct <= totalsize,
          sizeStruct <= totalsize - offStruct else { return -2 }
    guard offStrings <= totalsize, sizeStrings <= totalsize - offStrings else { return -3 }

    out.dtbBase = UInt64(UInt(bitPattern: fdt))
    out.dtbSize = totalsize

    let structEnd = min(Int(offStruct + sizeStruct), Int(totalsize))
    let strTable  = Int(offStrings)

    var ac = InlineArray<16, UInt32>(repeating: 2)
    var sc = InlineArray<16, UInt32>(repeating: 1)

    var depth    = 0
    var isUart   = false
    var isGic    = false
    var isMem    = false
    var isChosen = false

    var curReg    : Int?   = nil
    var curRegLen : UInt32 = 0
    var curIntr   : Int?   = nil
    var curIntrLen: UInt32 = 0

    var p = Int(offStruct)

    while p + 4 <= structEnd {
        let tag = fdt32(fdt, p); p += 4

        switch tag {
        case FDT.beginNode:
            let nameOff = p
            let name    = bytes(fdt, nameOff)
            var nlen = 0
            while nameOff + nlen < structEnd, name[nlen] != 0 { nlen += 1 }
            if nameOff + nlen >= structEnd { return 0 } // unterminated node name
            p += (nlen + 1 + 3) & ~3 // name + NUL, rounded up to a 4-byte cell
            if p > structEnd { return 0 }

            depth += 1
            if depth > 0, depth < FDT.maxDepth {
                ac[depth] = ac[depth - 1]
                sc[depth] = sc[depth - 1]
            }

            isChosen = ceq(name, "chosen")
            isUart   = false
            isGic    = false
            isMem    = depth == 2 && name[0] == UInt8(ascii: "m") && name[1] == UInt8(ascii: "e")

            curReg = nil; curRegLen = 0
            curIntr = nil; curIntrLen = 0

            if depth == 3,
               name[0] == UInt8(ascii: "c"), name[1] == UInt8(ascii: "p"),
               name[2] == UInt8(ascii: "u"), name[3] == UInt8(ascii: "@") {
                out.cpuCount += 1
            }

        case FDT.endNode:
            depth -= 1
            if depth == 0 { return 0 }
            isChosen = false; isUart = false; isMem = false; isGic = false

        case FDT.prop:
            if p + 8 > structEnd { return 0 }
            let len     = fdt32(fdt, p); p += 4
            let nameoff = fdt32(fdt, p); p += 4
            let dataOff = p
            p += (Int(len) + 3) & ~3 // property value, rounded up to a 4-byte cell
            if p > structEnd { return 0 }

            let validName = nameoff < sizeStrings
            let propName  = bytes(fdt, strTable + (validName ? Int(nameoff) : 0))

            let pac: UInt32 = (depth > 0 && depth < FDT.maxDepth) ? ac[depth - 1] : 2
            let psc: UInt32 = (depth > 0 && depth < FDT.maxDepth) ? sc[depth - 1] : 1

            if validName, ceq(propName, "#address-cells") {
                if depth < FDT.maxDepth { ac[depth] = fdt32(fdt, dataOff) }
            } else if validName, ceq(propName, "#size-cells") {
                if depth < FDT.maxDepth { sc[depth] = fdt32(fdt, dataOff) }
            } else if validName, ceq(propName, "reg") {
                curReg = dataOff; curRegLen = len
            } else if validName, ceq(propName, "interrupts") {
                curIntr = dataOff; curIntrLen = len
            } else if validName, ceq(propName, "bootargs") {
                out.bootargs = fdt.advanced(by: dataOff)
            }

            if isChosen, validName {
                if ceq(propName, "linux,initrd-start") {
                    out.initrdStart = readCells(fdt, dataOff, pac)
                } else if ceq(propName, "linux,initrd-end") {
                    out.initrdEnd = readCells(fdt, dataOff, pac)
                }
            }

            if validName, ceq(propName, "compatible") {
                var off  = dataOff
                var left = Int(len)
                while left > 0 {
                    let compat = bytes(fdt, off)
                    if ceq(compat, "arm,pl011") || ceq(compat, "arm,primecell") {
                        out.uart.type = 1 // UART_ARM_PL011
                        isUart = true
                    } else if ceq(compat, "ns16550a") || ceq(compat, "snps,dw-apb-uart") {
                        out.uart.type = 2 // UART_NS16550A
                        isUart = true
                    } else if ceq(compat, "arm,gic-400") || ceq(compat, "arm,cortex-a15-gic") {
                        isGic = true
                    }

                    var slen = 0
                    while slen < left, compat[slen] != 0 { slen += 1 }
                    slen += 1 // include NUL
                    if slen > left { break }
                    off  += slen
                    left -= slen
                }
            }

            if isUart {
                if let reg = curReg, curRegLen >= pac * 4 {
                    out.uart.baseAddr = readCells(fdt, reg, pac)
                }
                if let intr = curIntr, curIntrLen >= 8 {
                    out.uart.irq = fdt32(fdt, intr + 4) + 32
                }
            } else if isGic, let reg = curReg {
                let stride = pac + psc
                if curRegLen >= stride * 4 {
                    out.gic.gicdBase = readCells(fdt, reg, pac)
                }
                if curRegLen >= stride * 2 * 4 {
                    out.gic.giccBase = readCells(fdt, reg + Int(stride) * 4, pac)
                }
            } else if isMem, let reg = curReg, curRegLen >= (pac + psc) * 4 {
                out.ram.base = readCells(fdt, reg, pac)
                out.ram.size = readCells(fdt, reg + Int(pac) * 4, psc)
            }

        case FDT.nop:
            continue

        case FDT.end:
            return 0

        default:
            continue
        }
    }

    return 0
}

public func getPlatformInfo(
    _ info: inout PlatformInfo,
    at address: UnsafeRawPointer?
) -> Int32? {
    guard let address = address else { return -1 }

    return parsePlatformInfo(fdt: address, into: &info)
}
