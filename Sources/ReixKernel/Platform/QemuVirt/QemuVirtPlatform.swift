public enum QemuVirtPlatform: KernelPlatform {
    public static func discover(into info: inout PlatformInfo, at dtbAddress: PhysicalAddress) -> Bool {
        let dtbPointer = UnsafeRawPointer(bitPattern: Int(dtbAddress))
        return getPlatformInfo(&info, at: dtbPointer) != -1
    }
}
