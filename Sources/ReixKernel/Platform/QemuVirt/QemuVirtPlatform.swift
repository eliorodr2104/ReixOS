public enum QemuVirtPlatform: KernelPlatform {
    public static func discover(into info: inout PlatformInfo, at dtbAddress: PhysicalAddress) -> Bool {
        let dtbPointer = UnsafeRawPointer(bitPattern: Int(dtbAddress))
        // Only 0 means success. The parser returns negative codes for a bad
        // magic / malformed header; treating "!= -1" as success let -2/-3
        // (and any future error) through and booted on garbage platform info.
        return getPlatformInfo(&info, at: dtbPointer) == 0
    }
}
