# Storage service boundary

[Documentation home](../README.md) · [Disk layout](../Architecture/Storage.md) · [Services](Services.md)

Persistent storage has three layers: BlockServer operates the device, FileSystemServer owns a mounted volume, and ReixFS implements the format. Applications use scoped filesystem capabilities rather than kernel file descriptors.

## Ownership

Init derives diagnostic and warden views before giving the disk endpoint to FileSystemServer. The filesystem receives send authority without the ability to pass or derive the disk authority further. Init retains the warden view for volume-owner death handling.

FileSystemServer maintains client/object sessions and intersects requested filesystem operations with the granted `FSRights`, nine rights in all (see [the rights matrix](../ABI/Services.md#fsrights-and-the-badge)). Binding a narrower object or container creates a service capability rooted in that scope. The shell receives a filesystem view without unmount authority.

A client with the `claim` right can `lock` a file, and the server then refuses every other client's change to it with `busy` until `unlock`. Claims are refusals and never waits, and a claim held by a client that has died is swept before the server refuses. `claim` is a right of its own, not part of `write`, so a process can be given the ability to keep a file still while it reads it without the ability to rewrite it. ProcessServer's view of the program folder is the `loader` preset, `lookup`, `read` and `claim`, and [loads a program under such a claim](ProcessLaunch.md#loading-a-program-under-a-claim).

## Driver and queue

`VirtioBlock` currently uses a queue depth of 4 and 512-byte sectors. BlockClient allocates a shared window with one page per queue slot. Submission identifies a slot and sector range; collection identifies the completed slot and status. A client must wait for completion before treating the bytes in that slot as ready or reusing it.

At start the driver allocates its DMA buffer, resets the device and waits for the reset to take, then calls `dmaReclaim` on its own window, which gives back the buffers a dead predecessor left quarantined. Its own buffer is still held, so it is not among them. See [DMA quarantine](../Kernel/Memory.md#dma-quarantine).

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

`FileSystem<Device: BlockDevice>` takes a block backend and scratch memory sized for that device by `scratchBytes(sectorCount:sectorSize:)`; FileSystemServer asks for 112 KiB on the 16 MiB disk. It handles object records, directory names, extents, bitmap allocation, container quotas, transactions and recovery. `mount` returns `(disk: FileSystem?, found: FSMount)`: `ok`, `blank`, `unrecognised`, `tooLarge`, `corrupt`, `deviceFailed`, `unusable` or `durabilityUnknown`. `format` returns `(disk: FileSystem?, made: FSStatus)`.

Structural updates use a journal with room for 16 block images. Table, folder and file blocks carry checksums in the sum region, anchored by a root in the superblock. Changes to that region and root share a transaction. Existing file blocks overwritten in place are declared with their new checksums before writing, and interrupted declarations settle in their own transaction. A write starting in the partly filled last block journals the tail's image instead. A clean shutdown checks metadata and seals it, so the next sealed mount reads a few blocks instead of the whole table.

A file-data checksum failure returns `FSStatus.damaged`, with read progress stopping at the damaged block. It does not quarantine the volume. Writes retaining any damaged bytes are refused; a whole-block write can repair them. Table, folder or sum-region contradictions instead hold the volume. See [FSStatus](../../Sources/ABI/FileSystem/FSStatus.swift#L9).

## Mount refusal and consent

FileSystemServer keeps `mount`, `format` and `reanchor` separate. A blank disk needs a `BootMessage.blankDisk` request to its parent and an `allowed` reply before formatting. A corrupt mount result can offer re-anchoring only when a read-only full data scan finds a lone sum-root disagreement. The server then asks its parent through `BootMessage.sumRootMismatch` on the same channel. A failed exchange or any reply other than `allowed` authorizes no write.

Init handles that question in `awaitContainer`. It prints that re-anchoring trusts the medium's sum region and cannot tell a stale table and sum pair from a good one, then explicitly replies `allowed`. The repair repeats eligibility checks after consent and journals both superblock copies with the accepted root, mounted state and no seal. Other mount refusals stay refused. See [the re-anchor contract](../Architecture/Storage.md#consented-re-anchor).

## Scrub results

`fs.scrub` requests `scan(.data)`: metadata, the whole sum region against its known root, and every file block against its checksum. It reports `damaged-blocks:` from `Findings.damagedData`; a safe-to-serve result can still count damaged file blocks. A stopped walk is incomplete and cannot authorize repair. Ordinary mount checks metadata without reading every file's bytes.

[ShellFindingsFrame](../../Sources/ABI/Shell/ShellFindingsFrame.swift#L8) carries 21 ordered fields. `scrubDepth` is 0 for blocks, 1 for all metadata and 2 for data as well; the final field is `damagedBlocks` (`ShellField` 23). The other fields retain completion, quota/name checks, map discrepancies, room discrepancies, repair state and `safeToServe`.

The [disk format page](../Architecture/Storage.md) explains the byte/block layout and commit ordering. The scratch requirement is checked by [CensusTests.scratchIsEnough](../../Tests/FileSystemTests/CensusTests.swift#L270).

## Source entry points

[BlockServer / driver](../../Sources/Userland/BlockServer), [BlockClient](../../Sources/SDK/Clients/Block/BlockClient.swift), [FileSystemServer](../../Sources/Userland/FileSystemServer), [FileSystemClient](../../Sources/SDK/Clients/FileSystem/FileSystemClient.swift), [ReixFS](../../Sources/Libraries/FS).
