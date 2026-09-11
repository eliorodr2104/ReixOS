# Storage service boundary

[Documentation home](../README.md) · [Disk layout](../Architecture/Storage.md) · [Services](Services.md)

Persistent storage has three layers: BlockServer operates the device, FileSystemServer owns a mounted volume, and ReixFS implements the format. Applications use scoped filesystem capabilities rather than kernel file descriptors.

## Ownership

Init derives diagnostic and warden views before giving the disk endpoint to FileSystemServer. The filesystem receives send authority without the ability to pass or derive the disk authority further. Init retains the warden view for volume-owner death handling.

FileSystemServer maintains client/object sessions and intersects requested filesystem operations with the granted `FSRights`. Binding a narrower object or container creates a service capability rooted in that scope. The shell receives a filesystem view without unmount authority.

## Driver and queue

`VirtioBlock` currently uses a queue depth of 4 and 512-byte sectors. BlockClient allocates a shared window with one page per queue slot. Submission identifies a slot and sector range; collection identifies the completed slot and status. A client must wait for completion before treating the bytes in that slot as ready or reusing it.

IRQ delivery wakes the driver through the kernel's interrupt mechanism. Device completion, interrupt acknowledgement and IPC reply are separate steps. The driver tracks late/outstanding work and device-failure state.

## Main client interfaces

| Function | Parameters | Returns | Meaning |
| --- | --- | --- | --- |
| `BlockClient.init` | `block endpoint: UInt32` | `BlockClient?` | Establishes the session/window and reads device geometry. |
| `BlockClient.begin` | Count `UInt64`, sector `UInt64`, slot `Int` | `BlockStatus` | Submits a read into the selected shared slot. |
| `BlockClient.collect()` | None | `(slot: Int, status: BlockStatus)?` | Obtains a completion if available. |
| `BlockClient.read` / `write` | Count, sector, destination/source pointer | `BlockStatus` | Synchronous transfer through the client. |
| `FileSystemClient.init` | `fileSystem endpoint: UInt32` | `FileSystemClient?` | Establishes a filesystem client and its root scope. |
| `FileSystemClient.bind` | Object `UInt32`, `rights: FSRights` | `UInt32?` | Returns a scoped endpoint or failure. |
| `FileSystemClient.open` | Name pointer, length `Int`, optional folder `UInt32` | `(status: FSStatus, file: FSFile?)` | Resolves a child in the client's namespace. |
| `FileSystemClient.read` / `write` | Object, offset, buffer and count | `(status: FSStatus, bytes: UInt64)` | Transfers file bytes and reports actual progress. |
| `FileSystemClient.listBatch` | Folder, cursor, destination and capacity | `FSListBatchResult` | Bounded directory listing with continuation state. |

`BlockClient` stores endpoint, sector size/count and durability. `FileSystemClient` stores endpoint, root object and root-name data; its shared window is 4 pages. Transfer limits are checked by the client/server protocol rather than inferred from a pointer alone.

## Filesystem engine

`FileSystem<Device: BlockDevice>` takes a block backend and scratch memory. It handles object records, directory names, extents, bitmap allocation, container quotas, transactions and recovery. `mount` returns `(disk: FileSystem?, found: FSMount)`; `format` returns `(disk: FileSystem?, made: FSStatus)`.

Structural updates use a journal with room for 16 block images. File data and structural metadata follow different write paths. Checksums and recovery validate journal records before replay; malformed persistent state can quarantine the volume.

The [disk format page](../Architecture/Storage.md) explains the byte/block layout and commit ordering. It describes the implementation, not a new durability test result.

## Source entry points

[BlockServer / driver](../../Sources/Userland/BlockServer), [BlockClient](../../Sources/Reix/Services/BlockServer/BlockClient.swift), [FileSystemServer](../../Sources/Userland/FileSystemServer), [FileSystemClient](../../Sources/Reix/Services/FileSystemServer/FileSystemClient.swift), [ReixFS](../../Sources/ReixFS).
