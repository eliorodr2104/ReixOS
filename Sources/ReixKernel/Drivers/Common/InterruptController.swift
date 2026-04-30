public protocol InterruptController {
    static func initialize(dBase: UInt64, cBase: UInt64)
    static func enableInterrupt(id: UInt32)
    static func acknowledgeInterrupt() -> UInt32
    static func endOfInterrupt(id: UInt32)
}
