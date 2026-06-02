//
//  LoadedELF.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//


public struct LoadedELF {
    public let entryPoint: UInt64

    /// Physical backing of the ELF image.
    ///
    /// `nil` in the current loader: the image is loaded as individual
    /// page-sized, reference-counted `.anonymous` frames (one `ppm.alloc` per
    /// page) rather than a single contiguous block, so there is no single
    /// block to free. Each page is released per-VMA by `VMAManager.teardown`,
    /// which is also what lets a forked child share the pages copy-on-write
    /// and release them cleanly on exit.
    public let image     : PhysicalPage?

    public let loadBase  : UInt64
    public let loadEnd   : UInt64
}
