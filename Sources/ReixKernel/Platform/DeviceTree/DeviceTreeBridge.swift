//
//  DeviceTreeBridge.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

/// Walks the FDT struct block once, inheriting `#address-cells`/`#size-cells`
/// from parents, and fills `PlatformInfo` (RAM, UART, GIC, initrd, cpu count,
/// bootargs). All multi-byte fields in an FDT are big-endian; the blob is 4-byte
/// aligned, so every `UInt32` load lands on a 4-aligned address and stays safe
/// under `-mstrict-align`.
private enum FDT {
    static let beginNode: UInt32 = 0x1
    static let endNode  : UInt32 = 0x2
    static let prop     : UInt32 = 0x3
    static let nop      : UInt32 = 0x4
    static let end      : UInt32 = 0x9
    static let maxDepth = 16
    static let magic    : UInt32 = 0xd00dfeed

    /// Ceiling applied to `#address-cells` / `#size-cells`.
    ///
    /// The blob can claim any value, and the whole family of `pac * 4`,
    /// `(pac + psc) * 4`, `stride * 2 * 4` expressions below is trapping
    /// arithmetic on it, so an unbounded value is a boot-time panic on a
    /// malformed DTB and, in `readCells`, a walk off the end of the blob.
    /// Two is not an arbitrary bound: every consumer here folds the cells
    /// into a `UInt64`, so a third cell could not be represented anyway.
    static let maxCells: UInt32 = 2

    /// First INTID the GIC reserves; nothing at or above it is a line a
    /// device can own, so an `interrupts` cell that would land there is
    /// dropped rather than wrapped into a plausible-looking INTID.
    static let reservedInterrupt: UInt32 = 1020
}

@inline(__always)
private func fdt32(_ base: UnsafeRawPointer, _ off: Int) -> UInt32 {
    base.load(fromByteOffset: off, as: UInt32.self).byteSwapped
}

@inline(__always)
private func bytes(_ base: UnsafeRawPointer, _ off: Int) -> UnsafePointer<UInt8> {
    base.advanced(by: off).assumingMemoryBound(to: UInt8.self)
}

@inline(__always)
private func ceq(
    _ a        : UnsafePointer<UInt8>,
    _ available: Int,
    _ b        : StaticString
) -> Bool {
    let n  = b.utf8CodeUnitCount
    let bp = b.utf8Start
    if n >= available { return false }
    
    var i  = 0
    while i < n {
        let c = a[i]
        if c == 0 || c != bp[i] { return false }
        i += 1
    }
    
    return a[i] == 0
}

@inline(__always)
private func cStringLength(
    _ string   : UnsafePointer<UInt8>,
    _ available: Int
) -> Int? {
    var length = 0
    while length < available {
        if string[length] == 0 { return length }
        length += 1
    }
    return nil
}

@inline(__always)
private func checkedAdd(
    _ lhs: Int,
    _ rhs: Int
) -> Int? {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? nil : sum
}

@inline(__always)
private func paddedSize(_ size: Int) -> Int? {
    guard let sum = checkedAdd(size, 3) else { return nil }
    return sum & ~3
}

/// Combines `n` consecutive big-endian cells at byte offset `off` into a value.
///
/// `n` is clamped here as well as at the two properties it comes from:
/// this is the only place that turns a cell count into loads, so a bound
/// that lives with the loop cannot be bypassed by a future caller.
@inline(__always)
private func readCells(
    _ base: UnsafeRawPointer,
    _ off : Int,
    _ n   : UInt32
) -> UInt64 {
    var v: UInt64 = 0
    var i = 0
    
    let count = Int(min(n, FDT.maxCells))
    while i < count {
        v = (v << 32) | UInt64(fdt32(base, off + i * 4))
        i += 1
    }
    return v
}

/// Returns `nil` on success, and otherwise the guard that refused the blob.
func parsePlatformInfo(
         fdt: UnsafeRawPointer,
    into out: inout PlatformInfo
) -> DeviceTreeFault? {
    out.uart.type     = 0
    out.uart.baseAddr = 0
    out.cpuCount      = 0
    out.initrdStart   = 0
    out.initrdEnd     = 0

    guard UInt(bitPattern: fdt) & 3 == 0 else { return
        DeviceTreeFault(.misalignedBlob)
    }
    
    guard fdt32(fdt, 0) == FDT.magic else { return DeviceTreeFault(.badMagic) }

    let totalsize   = fdt32(fdt, 4)
    let offStruct   = fdt32(fdt, 8)
    let offStrings  = fdt32(fdt, 12)
    let sizeStrings = fdt32(fdt, 32)
    let sizeStruct  = fdt32(fdt, 36)

    let headerSize: UInt32 = 40
    guard totalsize >= headerSize else {
        return DeviceTreeFault(.shortHeader)
    }
    
    let (structEnd32, structOverflow) = offStruct.addingReportingOverflow(sizeStruct)
    guard offStruct >= headerSize,
          offStruct & 3 == 0,
          !structOverflow,
          structEnd32 <= totalsize else {
        return DeviceTreeFault(.structBlockBounds, at: Int(offStruct))
    }
    
    let (stringsEnd32, stringsOverflow) = offStrings.addingReportingOverflow(sizeStrings)
    guard offStrings >= headerSize,
          !stringsOverflow,
          stringsEnd32 <= totalsize else {
        return DeviceTreeFault(.stringBlockBounds, at: Int(offStrings))
    }
    
    guard structEnd32 <= offStrings ||
          stringsEnd32 <= offStruct else {
        return DeviceTreeFault(.overlappingBlocks, at: Int(offStrings))
    }

    out.dtbBase = UInt64(UInt(bitPattern: fdt))
    out.dtbSize = totalsize

    let structEnd = Int(structEnd32)
    let strTable  = Int(offStrings)

    var ac       = InlineArray<16, UInt32>(repeating: 2)
    var sc       = InlineArray<16, UInt32>(repeating: 1)
    var hasChild = InlineArray<16, Bool>(repeating: false)

    var depth      = 0
    var rootSeen   = false
    var rootClosed = false
    var isUart     = false
    var isGic      = false
    var isVirtio   = false
    var isMem      = false
    var isChosen   = false

    var curReg    : Int?   = nil
    var curRegLen : UInt32 = 0
    var curIntr   : Int?   = nil
    var curIntrLen: UInt32 = 0

    var p = Int(offStruct)

    // `tagOff` outlives the step over the tag, so every tag-level rejection
    // below reports the tag itself and not the word after it.
    while let next = checkedAdd(p, 4), next <= structEnd {
        let tagOff = p
        let tag = fdt32(fdt, p); p = next

        switch tag {
        case FDT.beginNode:
            let nameOff = p
            let name    = bytes(fdt, nameOff)

            // The alignment padding after the name is not inspected: the spec
            // calls it zeroed, but libfdt and QEMU both leave stale bytes there.
            guard let nlen = cStringLength(name, structEnd - nameOff),
                  let nameSize       = checkedAdd(nlen, 1),
                  let paddedNameSize = paddedSize(nameSize),
                  let nextName       = checkedAdd(p, paddedNameSize),
                  nextName <= structEnd else {
                return DeviceTreeFault(.nodeName, at: nameOff)
            }

            guard depth < FDT.maxDepth - 1 else {
                return DeviceTreeFault(.depthLimit, at: nameOff)
            }
                
            if depth == 0 {
                // Depth returns to 0 only through the `endNode` that closes the
                // root, so a node here is a second top-level node, not the root.
                if rootClosed { return DeviceTreeFault(.orphanNode, at: nameOff) }
                if nlen != 0  { return DeviceTreeFault(.rootNode, at: nameOff) }
                
                rootSeen = true
                
            } else { hasChild[depth] = true }
            p = nextName

            depth += 1
            hasChild[depth] = false
            if depth > 0, depth < FDT.maxDepth {
                ac[depth] = ac[depth - 1]
                sc[depth] = sc[depth - 1]
            }

            isChosen = ceq(name, nlen + 1, "chosen")
            isUart   = false
            isGic    = false
            isVirtio = false
            isMem    = depth == 2 &&
                       nlen >= 2 &&
                       name[0] == UInt8(ascii: "m") &&
                       name[1] == UInt8(ascii: "e")

            curReg  = nil; curRegLen  = 0
            curIntr = nil; curIntrLen = 0

            if depth == 3, nlen >= 4,
               name[0] == UInt8(ascii: "c"), name[1] == UInt8(ascii: "p"),
               name[2] == UInt8(ascii: "u"), name[3] == UInt8(ascii: "@") {
                out.cpuCount += 1
            }

        case FDT.endNode:
            if !rootSeen || rootClosed || depth <= 0 {
                return DeviceTreeFault(.strayEndNode, at: tagOff)
            }
            depth -= 1
            if depth == 0 { rootClosed = true }
            isChosen = false; isUart = false; isMem = false; isGic = false

        case FDT.prop:
            
                if !rootSeen || rootClosed || depth <= 0 || depth >= FDT.maxDepth || hasChild[depth] {
                return DeviceTreeFault(.strayProperty, at: tagOff)
            }
                
            guard let propertyHeaderEnd = checkedAdd(p, 8), propertyHeaderEnd <= structEnd else {
                return DeviceTreeFault(.propertyHeader, at: tagOff)
            }
                
            let len     = fdt32(fdt, p)
            let nameoff = fdt32(fdt, p + 4)
                
            p = propertyHeaderEnd
            let dataOff = p
            guard let paddedPropertySize = paddedSize(Int(len)),
                  let propertyEnd = checkedAdd(p, paddedPropertySize),
                  propertyEnd <= structEnd else {
                return DeviceTreeFault(.propertyValueBounds, at: dataOff)
            }

            // Padding after the value is not inspected either, for the reason
            // given at the node-name guard: only the bounds of the value matter.
            p = propertyEnd

            guard nameoff < sizeStrings,
                  let propNameOffset = checkedAdd(strTable, Int(nameoff)) else {
                return DeviceTreeFault(.propertyName, at: dataOff)
            }
            let propNameAvailable = Int(sizeStrings - nameoff)
            let propName = bytes(fdt, propNameOffset)
            guard cStringLength(propName, propNameAvailable) != nil else {
                return DeviceTreeFault(.propertyName, at: propNameOffset)
            }

            let pac: UInt32 = (depth > 0 && depth < FDT.maxDepth) ? ac[depth - 1] : 2
            let psc: UInt32 = (depth > 0 && depth < FDT.maxDepth) ? sc[depth - 1] : 1

            if ceq(propName, propNameAvailable, "#address-cells") {
                if depth < FDT.maxDepth, len >= 4 {
                    ac[depth] = min(fdt32(fdt, dataOff), FDT.maxCells)
                }
                
            } else if ceq(propName, propNameAvailable, "#size-cells") {
                if depth < FDT.maxDepth, len >= 4 {
                    sc[depth] = min(fdt32(fdt, dataOff), FDT.maxCells)
                }
                
            } else if ceq(propName, propNameAvailable, "reg") {
                curReg = dataOff; curRegLen = len
                
            } else if ceq(propName, propNameAvailable, "interrupts") {
                curIntr = dataOff; curIntrLen = len
                
            } else if ceq(propName, propNameAvailable, "bootargs") {
                out.bootargs = fdt.advanced(by: dataOff)
            }

            
            if isChosen, len >= 4 {
                let cells = min(pac, len / 4)

                if ceq(propName, propNameAvailable, "linux,initrd-start") {
                    out.initrdStart = readCells(fdt, dataOff, cells)
                    
                } else if ceq(propName, propNameAvailable, "linux,initrd-end") {
                    out.initrdEnd = readCells(fdt, dataOff, cells)
                }
            }

            if ceq(propName, propNameAvailable, "compatible") {
                var off  = dataOff
                var left = Int(len)
                
                while left > 0 {
                    let compat = bytes(fdt, off)
                    guard let slen = cStringLength(compat, left) else {
                        return DeviceTreeFault(.compatibleList, at: off)
                    }
                    
                    if ceq(compat, left, "arm,pl011") || ceq(compat, left, "arm,primecell") {
                        out.uart.type = 1 // UART_ARM_PL011
                        isUart = true
                        
                    } else if ceq(compat, left, "ns16550a") || ceq(compat, left, "snps,dw-apb-uart") {
                        out.uart.type = 2 // UART_NS16550A
                        isUart = true
                        
                    } else if ceq(compat, left, "arm,gic-400") || ceq(compat, left, "arm,cortex-a15-gic") {
                        isGic = true

                    } else if ceq(compat, left, "virtio,mmio") {
                        isVirtio = true
                    }

                    guard let stringSize = checkedAdd(slen, 1),
                          let nextString = checkedAdd(off, stringSize) else {
                        return DeviceTreeFault(.compatibleList, at: off)
                    }
                    off = nextString
                    left -= stringSize
                }
            }

            if isUart {
                if let reg = curReg, curRegLen >= pac * 4 {
                    out.uart.baseAddr = readCells(fdt, reg, pac)
                }
                if let intr = curIntr, curIntrLen >= 8 {
                    
                    let kind   = fdt32(fdt, intr)
                    let base   = kind == 1 ? UInt32(16) : UInt32(32)
                    let number = fdt32(fdt, intr + 4)

                    if number < FDT.reservedInterrupt - base {
                        out.uart.irq = number + base
                    }
                }
            } else if isVirtio,
                      let reg = curReg, curRegLen >= (pac + psc) * 4,
                      let intr = curIntr, curIntrLen >= 8 {

                let base = readCells(fdt, reg, pac)
                let size = readCells(fdt, reg + Int(pac) * 4, psc)

                let kind    = fdt32(fdt, intr)
                let intBase = kind == 1 ? UInt32(16) : UInt32(32)
                let number  = fdt32(fdt, intr + 4)

                // Only the bound that keeps the addition below honest is checked
                // here. Everything else a node can get wrong is `include`'s to
                // refuse, so there is one door and one place that counts what
                // came through it.
                if number < FDT.reservedInterrupt - intBase {
                    out.virtioBus.include(base: base, size: size, line: number + intBase)
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
            guard p == structEnd, depth == 0, rootSeen, rootClosed else {
                return DeviceTreeFault(.misplacedEnd, at: tagOff)
            }
            return nil

        default:
            return DeviceTreeFault(.unknownTag, at: tagOff)
        }
    }

    return DeviceTreeFault(.unterminatedStruct, at: p)
}

/// Bounds of the initrd linked into the kernel image, from `linker.ld`.
///
/// Declared here rather than in `LinkerSymbols.swift` because this is the only
/// place that reads them. They coincide when nothing was linked into `.initrd`.
@_silgen_name("_initrd_start")
public var _initrd_start: UInt8

@_silgen_name("_initrd_end")
public var _initrd_end: UInt8

/// Returns `nil` once `info` is filled, and otherwise the guard that stopped it.
///
/// Includes one check the walk cannot make, that the blob actually named a
/// console. A well-formed tree with no UART node, or with one whose `reg` is
/// missing or shorter than `#address-cells`, reaches `FDT_END` with nothing
/// wrong in it and `uart.baseAddr` still zero, and that is not a base the kernel
/// can survive either way it is read: before `enable_mmu` it resolves to null
/// and `PL011UART` drops every byte, so the entire boot log would go silently
/// nowhere, and after `enable_mmu` it stops being null at all, because
/// `physicalOffset &+ 0` is an ordinary address in the device window and the log
/// would be written into whatever physical page zero belongs to. Both are worse
/// than refusing the blob, so the blob is refused.
public func getPlatformInfo(
    _  info   : inout PlatformInfo,
    at address: UnsafeRawPointer?
) -> DeviceTreeFault? {
    guard let address = address else {
        return DeviceTreeFault(.missingBlob)
    }

    if let fault = parsePlatformInfo(
        fdt : address,
        into: &info
    ) { return fault }

    // The walk can only say the blob is well-formed, not that it named a
    // console. See above for why zero is refused rather than carried forward.
    guard info.uart.baseAddr != 0 else { return DeviceTreeFault(.missingConsole) }

    // A boot without `-initrd` leaves /chosen without the two properties, and
    // the copy carried inside the kernel image is then the only archive there is.
    if info.initrdEnd <= info.initrdStart {
        let start = getOfaddressWithSymbol(of: &_initrd_start)
        let end   = getOfaddressWithSymbol(of: &_initrd_end)

        // Called before the MMU is on, so these are physical addresses, which
        // is what `initrdStart` means everywhere it is read.
        if end > start {
            info.initrdStart = start
            info.initrdEnd   = end
        }
    }

    return nil
}
