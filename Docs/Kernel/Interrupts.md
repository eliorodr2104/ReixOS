# Interrupts and kernel drivers

[Documentation home](../README.md) · [Kernel overview](Overview.md) · [System map](../Architecture/System.md)

The kernel retains the GICv2 interrupt controller, timer handling and low-level PL011 UART access used by boot and diagnostics. Runtime serial service and the virtio-block device driver are userland components.

## IRQ delivery

1. Read the GIC acknowledgement value.
2. Handle the virtual timer locally, or find the claimed interrupt owner.
3. For a user-owned line, mask it and mark the corresponding `InterruptSet` bit pending.
4. Deliver an endpoint notification or resume an IRQ waiter.
5. End the GIC interrupt. The userland driver services its device and acknowledges the handled bits through the IRQ API.

Masking at delivery prevents an unserviced level-triggered source from repeatedly entering the kernel. `InterruptClaims` maps lines to their owner; `InterruptSet` records pending, masked and waiter state.

## Boundaries

| Component | Responsibility |
| --- | --- |
| `GICv2` | Enable/disable lines, acknowledge and end interrupts. |
| `VirtualTimerInterruptHandler` | Timer tick and scheduling/deadline work. |
| `InterruptDispatcher` | Route acknowledged interrupts to the timer or holder. |
| `MMIO` and register interfaces | Typed reads/writes at device addresses. |
| `PL011UART` | Kernel serial I/O for early output and diagnostics. |
| EL0 `SerialServer` / `BlockServer` | Device protocol, queues and service requests. |

A device capability, an interrupt capability and a DMA capability grant different powers. Their presence should not be inferred from the service's name.

## Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>InterruptDispatcher.dispatch(ack:frame:)</code>](../../Sources/ReixKernel/Drivers/InterruptController/InterruptDispatcher.swift#L26) | <code>ack : UInt32, frame: UnsafeMutablePointer&lt;Arch.TrapFrame&gt;</code> | <code>Void</code> | Routes the acknowledged IRQ and ends it at the GIC. |
