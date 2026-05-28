//
//  Banner.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Plain-ASCII boot banner. Printed once by `Kernel.boot` before the
/// first subsystem comes up.
///
/// The figlet is hand-tuned standard ASCII so it renders identically on
/// any 7-bit serial terminal (no UTF-8 box-drawing, no escape codes).
public func printBootBanner() {
    kprint()
    kprint(" ReixOS 0.1.0  AArch64 / Embedded Swift")
    kprint(" (c) 2026 Eliomar Alejandro Rodriguez Ferrer")
    kprint()
}
