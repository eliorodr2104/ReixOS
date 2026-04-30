public protocol KernelPlatform {
    static func discover(into info: inout PlatformInfo, at dtbAddress: PhysicalAddress) -> Bool
}
