/// Contract every interrupt controller driver must satisfy.
///
/// Instance-based by design: the controller owns mutable register
/// pointers and must be reachable through a stable pointer so the
/// exception vector can perform mutating acknowledge/EOI operations
/// without copying the driver.
public protocol InterruptController {

    init(dBase: UInt64, cBase: UInt64)

    func enableInterrupt(id: UInt32)
    func acknowledgeInterrupt() -> UInt32
    func endOfInterrupt(id: UInt32)
}
