//
//  KernelRuntimeDiagnostic.swift
//  ReixOS
//

#if REIX_RUNTIME_DIAGNOSTIC || REIX_RUNTIME_STACK_DIAGNOSTIC

@_extern(c, "reix_runtime_probe_malloc")
private func runtimeProbeMalloc(_ size: UInt) -> UnsafeMutableRawPointer?

@_extern(c, "reix_runtime_probe_free")
private func runtimeProbeFree(_ pointer: UnsafeMutableRawPointer?)

@_extern(c, "reix_runtime_probe_posix_memalign")
private func runtimeProbePosixMemalign(
    _ output   : UnsafeMutablePointer<UnsafeMutableRawPointer?>,
    _ alignment: UInt,
    _ size     : UInt
) -> Int32

@_extern(c, "reix_runtime_probe_arc4random_buf")
private func runtimeProbeArc4RandomBuf(_ buffer: UnsafeMutableRawPointer?, _ count: UInt)

@_extern(c, "reix_runtime_probe_stack_check")
private func runtimeProbeStackCheck()

enum KernelRuntimeDiagnostic {
    static func triggerStackFailure() -> Never {
        runtimeProbeStackCheck()
        Arch.CPU.panic("runtime ABI diagnostic: stack check returned")
    }

    static func run(ppm: UnsafeMutablePointer<KernelPPM>) {
        let pagesBefore = ppm.pointee.allocatedPages

        guard let zero = runtimeProbeMalloc(0), UInt(bitPattern: zero) & 15 == 0 else {
            Arch.CPU.panic("runtime ABI diagnostic: malloc zero/alignment failed")
        }
        zero.storeBytes(of: UInt8(0xA5), as: UInt8.self)
        runtimeProbeFree(zero)
        runtimeProbeFree(nil)

        var aligned: UnsafeMutableRawPointer?
        guard runtimeProbePosixMemalign(&aligned, 4096, 4097) == 0,
              let aligned,
              UInt(bitPattern: aligned) & 4095 == 0
        else {
            Arch.CPU.panic("runtime ABI diagnostic: posix_memalign failed")
        }
        aligned.storeBytes(of: UInt8(0xC3), as: UInt8.self)
        (aligned + 4096).storeBytes(of: UInt8(0x3C), as: UInt8.self)
        guard aligned.load(as: UInt8.self) == 0xC3,
              (aligned + 4096).load(as: UInt8.self) == 0x3C
        else {
            Arch.CPU.panic("runtime ABI diagnostic: aligned payload failed")
        }
        runtimeProbeFree(aligned)

        // This is the supported Swift runtime lifecycle in the kernel. Class
        // allocation is compile-time forbidden because high-half pointers use
        // the runtime's immortal marker bit; the harness proves that guardrail.
        let manual = UnsafeMutableRawPointer.allocate(byteCount: 5000, alignment: 4096)
        manual.storeBytes(of: UInt8(0x69), as: UInt8.self)
        (manual + 4999).storeBytes(of: UInt8(0x96), as: UInt8.self)
        guard UInt(bitPattern: manual) & 4095 == 0,
              manual.load(as: UInt8.self) == 0x69,
              (manual + 4999).load(as: UInt8.self) == 0x96
        else {
            Arch.CPU.panic("runtime ABI diagnostic: Swift raw allocation failed")
        }
        manual.deallocate()

        var seed = (UInt64(0), UInt64(0))
        withUnsafeMutableBytes(of: &seed) { bytes in
            runtimeProbeArc4RandomBuf(bytes.baseAddress, UInt(bytes.count))
        }
        guard seed.0 == 0x4242_4242_4242_4242,
              seed.1 == 0x4242_4242_4242_4242
        else {
            Arch.CPU.panic("runtime ABI diagnostic: deterministic seed changed")
        }

        var hasher = Hasher()
        hasher.combine(UInt64(0x5245_4958_5255_4E54))
        let hash = UInt(bitPattern: hasher.finalize())

        guard ppm.pointee.allocatedPages == pagesBefore else {
            Arch.CPU.panic("runtime ABI diagnostic: heap pages not restored")
        }

        kprint("[ RUNTIME ABI PASS ] hash=0x\(hex: hash)")
    }
}

#endif
