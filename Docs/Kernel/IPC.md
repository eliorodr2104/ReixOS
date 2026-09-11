# IPC and capabilities

[Documentation home](../README.md) · [System map](../Architecture/System.md)

## Authority and object lifetime

A capability combines a target, a rights mask and a badge. Each process has its own `CapsTable`; userland passes a table handle rather than a kernel pointer.

### Representation

| Member | Type | Role |
| --- | --- | --- |
| `Capability.target` | `CapTarget` | Endpoint, shared/DMA region, device, bus, interrupt set, task/job or control authority. |
| `Capability.rights` | `CapRights` | Operations permitted for that target. |
| `Capability.badge` | `Badge` (`UInt64`) | Server-visible session identity attached to the capability. |
| Table handle | `UInt32` | Index in the caller's capability table. |
| Table capacity | 32 slots | Fixed per-process capacity. |

Rights are interpreted together with the target. Some bit positions have target-specific meanings, such as device read/write versus profiler permissions; a numeric bit is not a universal operation.

### Derivation and transfer

`CapsTable.mint` requires a source with `.derive`, badge zero and a nonzero requested session. It intersects requested rights with the source rights and removes `.derive` from the result. A derived endpoint view therefore cannot invent new authority or derive another badge through this path.

`RendezvousIPC` performs capability transfer, target reference accounting and capability release. Removing a table entry alone is not sufficient to release a shared target: use the ownership-aware path. Bootstrap grants install explicitly selected rights into child slots.

`DeviceRegion`, `BusAuthority` and `InterruptSet` keep device access and interrupt ownership explicit. DMA authority permits the device-facing physical-memory path; the current hardware path does not provide an IOMMU isolation layer.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>CapsTable.install(_:)</code>](../../Sources/ReixKernel/InterProcessControl/Capabilities/CapsTable.swift#L35) | <code>_ cap: Capability</code> | <code>UInt32?</code> | Returns the installed handle, or `nil` if no slot is available. |
| [<code>CapsTable.resolve(_:)</code>](../../Sources/ReixKernel/InterProcessControl/Capabilities/CapsTable.swift#L113) | <code>_ handle: UInt32</code> | <code>Capability?</code> | Returns the capability in that slot, or `nil` for an absent/out-of-range handle. |
| [<code>CapsTable.mint(from:session:rights:)</code>](../../Sources/ReixKernel/InterProcessControl/Capabilities/CapsTable.swift#L135) | <code>from handle: UInt32, session : Badge, rights : CapRights</code> | <code>UInt32?</code> | Returns an attenuated, badged handle, or `nil` when derivation or allocation fails. |
| [<code>RendezvousIPC.transferCapability(from:handler:to:rights:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L657) | <code>from senderProcess : UnsafeMutablePointer&lt;Process&gt;, handler : UInt32, to receiverProcess: UnsafeMutablePointer&lt;Process&gt;, rights : CapRights</code> | <code>Result&lt;UInt32, IPCError&gt;</code> | Installs an allowed share in the receiver and returns its local handle, or an IPC error. |
| [<code>RendezvousIPC.releaseCapability(_:of:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L1358) | <code>_ handle : UInt32, of process: UnsafeMutablePointer&lt;Process&gt;</code> | <code>Result&lt;Void, IPCError&gt;</code> | Removes a capability and releases the target reference through the matching ownership path. |

## Message delivery and waiting

`RendezvousIPC` implements synchronous endpoint communication. A message carries a tag and four 32-bit words. Larger data travels through explicitly shared memory, with IPC carrying the operation and transfer metadata.

### Operations

| Operation | Behavior |
| --- | --- |
| `send` / `receive` | Match a sender and receiver, or block when the blocking form permits it. |
| `trySend` / `tryReceive` | Attempt a transfer without waiting for a peer. |
| Timed receive | Wait with a deadline registered in the shared deadline queue. |
| `call` | Send a request and wait for its reply. |
| `reply` | Complete a caller waiting on the server. |
| `replyRecv` | Reply and enter the next receive through one kernel operation. |

An endpoint stores its matching/wait state. A blocked sender's `Process.pending` stores the pending message; a call establishes reply relationships between process records. The implementation also supports deferred replies, with a current limit of **8** per server.

### Stored state

| Member | Type / limit | Meaning |
| --- | --- | --- |
| `endpoints` | `InlineArray<64, UnsafeMutablePointer<Endpoint>?>` | Endpoint registry. |
| `ppm`, `heap`, `scheduler` | Stable manager pointers | Shared-memory ownership, endpoint allocation and waiter transitions. |
| `PendingMessage` | Message plus delivery/authority state | Transfer waiting for a receiver. |
| `replyTo`, `replyPartner`, `nextWaiter` | Process relationships | Active and deferred reply bookkeeping. |

Interrupt sets can be bound to endpoints. Notification delivery and ordinary messages share a receive path, but an interrupt notification is not authority to touch an unrelated device.

See [IPC ABI](../ABI/IPC.md) for register encoding and [IPC SDK](../ABI/IPC.md) for userland return types and grant ownership.

### Main interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| [<code>RendezvousIPC.send(capability:frame:blocking:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L37) | <code>capability: Capability, frame : AArch64.TrapFrame, blocking : Bool = true</code> | <code>Result&lt;CommunicationMessageResult, IPCError&gt;</code> | Returns a communication outcome or IPC error; a blocking outcome leaves the sender waiting. |
| [<code>RendezvousIPC.receive(capability:frame:blocking:timeoutTicks:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L171) | <code>capability : Capability, frame : UnsafeMutablePointer&lt;AArch64.TrapFrame&gt;, blocking : Bool = true, timeoutTicks: UInt64? = nil</code> | <code>Result&lt;CommunicationMessageResult, IPCError&gt;</code> | Receives or waits according to the supplied policy and optional deadline. |
| [<code>RendezvousIPC.call(capability:frame:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L306) | <code>capability: Capability, frame : AArch64.TrapFrame</code> | <code>Result&lt;CommunicationMessageResult, IPCError&gt;</code> | Starts a request/reply exchange and tracks the waiting caller. |
| [<code>RendezvousIPC.reply(frame:target:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L402) | <code>frame : AArch64.TrapFrame, target: UnsafeMutablePointer&lt;Process&gt;? = nil</code> | <code>Result&lt;CommunicationMessageResult, IPCError&gt;</code> | Replies to the selected or current caller and reports the communication outcome. |
| [<code>RendezvousIPC.spawnEndpoint(for:rights:owner:)</code>](../../Sources/ReixKernel/InterProcessControl/RendezvousIPC.swift#L502) | <code>for process: UnsafeMutablePointer&lt;Process&gt;, rights : CapRights = [.send, .receive, .grant, .derive], owner : PID? = nil</code> | <code>Result&lt;UInt32, IPCError&gt;</code> | Creates an endpoint and returns its process-local capability handle. |
