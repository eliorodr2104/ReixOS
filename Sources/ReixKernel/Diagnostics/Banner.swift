//
//  Banner.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/05/2026.
//

/// Plain-ASCII boot banner. Printed once by `Kernel.boot` before the
/// first subsystem comes up.
///
/// Deliberately understated, in the same `[ tag ]` column style as the boot
/// log that follows. Pure 7-bit ASCII so it renders identically on any serial
/// terminal (no UTF-8 box-drawing, no escape codes).
public func printBootBanner() {
    kprint()
    kprint()
    kprint("[ reix ] ReixOS 0.1.5 / AArch64 / Embedded Swift")
    kprint("[ reix ] (c) 2026 Eliomar Alejandro Rodriguez Ferrer - GPLv3")
    kprint()
}
