//
//  QemuVirtPlatform.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/05/2026.
//

public enum QemuVirtPlatform: KernelPlatform, Loggable {

    public static let nameLog : StaticString = "[BOOT]"
    public static let logLevel: LogLevel     = .info

    /// Where the virt machine's PL011 always is, and `UART_ARM_PL011` as
    /// `UartInfo.type` spells it.
    ///
    /// Not a shortcut around discovery: it is read on the failure path only, by
    /// `installBootConsole`, and a boot that got its device tree keeps whatever
    /// base the blob gave it. The address is part of the machine QEMU emulates,
    /// which is what makes it the platform's to know: `virt` has published this
    /// mapping since it gained a PL011 and cannot move it without breaking every
    /// other guest.
    private static let pl011Base: UInt64 = 0x0900_0000
    private static let pl011Type: UInt32 = 1

    public static func discover(into info: inout PlatformInfo, at dtbAddress: PhysicalAddress) -> DeviceTreeFault? {
        let dtbPointer = UnsafeRawPointer(bitPattern: Int(dtbAddress))
        // Only nil means success: the walk names several distinct rejections,
        // and testing "!= -1" once let two of them boot on garbage info.
        return getPlatformInfo(&info, at: dtbPointer)
    }

    /// Aims `PL011UART` at the machine's own PL011 so a failed discovery can be
    /// said out loud.
    ///
    /// Discovery is the only thing that tells the driver where to write, so a
    /// failure left `uart.baseAddr` at zero, the error line about it dereferenced
    /// null, trapped, and re-trapped inside the panic printer on the same zero:
    /// the loudest failure the kernel has arrived as an empty serial log.
    ///
    /// Called from the failure branch and from nowhere else, one statement before
    /// the CPU parks, so no subsystem can grow a dependency on a base address
    /// that did not come out of a device tree.
    public static func installBootConsole(into info: inout PlatformInfo) {
        info.uart.baseAddr = pl011Base
        info.uart.type     = pl011Type
    }
}
