//
//  KernelPlatform.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//

public protocol KernelPlatform {

    /// Fills `info` from the blob at `dtbAddress`. `nil` means success, and
    /// anything else is the check that refused the blob, for the boot to print.
    static func discover(
        into info      : inout PlatformInfo,
        at   dtbAddress: PhysicalAddress
    ) -> DeviceTreeFault?

    /// Points the logger at a console the platform knows without discovering it.
    ///
    /// Exists for one caller, the failure branch of `Kernel.boot`, and has to be
    /// answerable by a platform that has just been told its device tree is
    /// unusable: whatever it installs must come from what the machine is, never
    /// from what the blob said.
    static func installBootConsole(into info: inout PlatformInfo)
}
