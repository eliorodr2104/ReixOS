public enum QemuVirtPlatform: KernelPlatform, Loggable {
    
    public static let nameLog : StaticString = "[BOOT]"
    public static let logLevel: LogLevel     = .info
    
    public static func discover(into info: inout PlatformInfo, at dtbAddress: PhysicalAddress) -> Bool {
        let dtbPointer = UnsafeRawPointer(bitPattern: Int(dtbAddress))
        // Only 0 means success: the parser returns several negative codes, and
        // testing "!= -1" let -2/-3 through and booted on garbage platform info.
        return getPlatformInfo(&info, at: dtbPointer) == 0
    }
}
