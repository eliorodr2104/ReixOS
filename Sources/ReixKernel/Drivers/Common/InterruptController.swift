/// How a device asserts its interrupt line.
///
/// Level sources hold the line up until the driver services the device,
/// so the kernel has to mask them before it hands the event over and
/// unmask on the acknowledgement; edge sources need neither.
public enum InterruptTrigger {
    case edge
    case level
}

/// Contract every interrupt controller driver must satisfy.
///
/// Instance-based by design: the controller owns mutable register
/// pointers and must be reachable through a stable pointer so the
/// exception vector can perform mutating acknowledge/EOI operations
/// without copying the driver.
public protocol InterruptController {

    init(dBase: UInt64, cBase: UInt64)

    func configureInterrupt(id: UInt32, trigger: InterruptTrigger)
    func enableInterrupt(id: UInt32)
    func disableInterrupt(id: UInt32)
    func acknowledgeInterrupt() -> UInt32
    func endOfInterrupt(ack: UInt32)
}
