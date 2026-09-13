//
//  FPContextDiagnostic.swift
//  ReixOS
//

#if REIX_FPSIMD_DIAGNOSTIC

@_silgen_name("fpsimd_run_nested_probe")
private func fpsimdRunNestedProbe() -> UInt64

@_silgen_name("fpsimd_diagnostic_environment_failed")
private func fpsimdDiagnosticEnvironmentFailed() -> UInt64

/// Entry points for the isolated FP/SIMD diagnostic image. The production
/// kernel does not compile these calls or link their assembly implementation.
enum FPContextDiagnostic {

    /// Called at the start of every Swift exception handler. ContextSaving.S
    /// records whether FPCR/FPSR were canonical immediately before the call.
    @inline(__always)
    static func requireCanonicalEnvironment() {
        guard fpsimdDiagnosticEnvironmentFailed() == 0 else {
            Arch.CPU.panic("FP/SIMD diagnostic: Swift inherited non-canonical FP state")
        }
    }

    /// Waits in EL1 for a timer interrupt with sentinels in every Q register
    /// and in FPCR/FPSR. The diagnostic vector path intentionally clobbers all
    /// of them after saving the nested frame; the helper verifies the return.
    static func runNestedEL1Probe() {
        let result = fpsimdRunNestedProbe()

        guard result == 0 else {
            kprint("[FPSIMD] nested EL1 diagnostic failed, code \(result).")
            Arch.CPU.panic("FP/SIMD diagnostic: nested EL1 state was not preserved")
        }

        kprint("[FPSIMD] nested EL1 state and kernel FP environment preserved.")
    }
}

#endif
