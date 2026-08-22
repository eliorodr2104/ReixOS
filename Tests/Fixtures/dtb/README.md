# Device tree corpus

Real flattened device trees, dumped straight out of QEMU. These are the blobs
`DeviceTreeBridge` sees on a live boot, not hand-written approximations, and
they are what the corpus and mutation suites parse
(`Tests/KernelPolicyTests/DeviceTreeCorpusTests.swift`,
`Tests/KernelPolicyTests/DeviceTreeMutationTests.swift`).

## Tooling

| | |
|---|---|
| Tool | `qemu-system-aarch64` (Homebrew, `/opt/homebrew/bin`) |
| Version | `QEMU emulator version 11.0.0` (`qemu-system-aarch64 --version`) |
| Host | macOS 26 (Darwin 25.5.0), arm64 |
| Captured | 2026-08-09 |

`-machine virt,...,dumpdtb=<path>` makes QEMU build the machine, write the
device tree it would have handed the kernel, and exit. Nothing boots, no guest
code runs, and no image is loaded from the repo.

## Artifacts

### `virt-gicv2-128m.dtb` (1048576 bytes)

    qemu-system-aarch64 \
        -machine virt,gic-version=2,dumpdtb=Tests/Fixtures/dtb/virt-gicv2-128m.dtb \
        -cpu cortex-a53 -m 128M -nographic

sha256 `6f9a531d284c31940c1076471870ad1ed925ab213061adf2f23a991a9c281845`

### `virt-gicv2-4m.dtb` (1048576 bytes)

The same machine at the project's RAM floor, so the corpus holds both ends of
the range `make run` and `make run-4m` boot.

    qemu-system-aarch64 \
        -machine virt,gic-version=2,dumpdtb=Tests/Fixtures/dtb/virt-gicv2-4m.dtb \
        -cpu cortex-a53 -m 4M -nographic

sha256 `4ce2db46560025be33d948a6b39348668819b222aa3c9f7d00514b59ef24b115`

The only difference from the 128M dump is the second cell of
`/memory@40000000`'s `reg`: `0x00400000` instead of `0x08000000`.

### `virt-gicv2-128m-initrd.dtb` (1048576 bytes)

The first two dumps come from a machine that was never given a kernel, so
QEMU leaves `/chosen` empty and `linux,initrd-start` / `linux,initrd-end`
never appear. Those two properties are the ones `getPlatformInfo` reads to
find the initrd, and without them the fallback to the archive linked into the
kernel image is all a test can observe. This third dump carries them.

Two throwaway inputs, in the scratchpad rather than in the repo:

    python3 -c "open('fake-kernel.bin','wb').write(b'\x00'*4096)"
    python3 -c "open('fake-initrd.bin','wb').write(b'R'*8192)"

    qemu-system-aarch64 \
        -machine virt,gic-version=2,dumpdtb=Tests/Fixtures/dtb/virt-gicv2-128m-initrd.dtb \
        -cpu cortex-a53 -m 128M -nographic \
        -kernel fake-kernel.bin -initrd fake-initrd.bin

sha256 `fcd103ea0f9d2d1ef5f7b9710f9761b5c031f3c766469c6187013c1417bd7e40`

`-kernel` is only there to make QEMU run its image loader, which is what adds
`/chosen`; the 4096 zero bytes are never executed. The resulting properties are
`linux,initrd-start = <0x0 0x44000000>` and `linux,initrd-end = <0x0 0x44002000>`,
that is the 8192 bytes of `fake-initrd.bin` placed after the loaded image.

Re-capturing this one does **not** reproduce the bytes: `/chosen` also gets
`rng-seed` and `kaslr-seed`, which QEMU fills from the host RNG on every run.
Everything the kernel reads out of it is stable; the sha256 above is not.

## On the size

Every dump is exactly 1 MiB, and so is the `totalsize` in its header: the virt
machine reserves a 1 MiB window for the device tree and declares the whole of
it, so the ~7 KiB of real tree is followed by ~1041 KiB of zero padding that is
still *inside* the blob. The files are not trimmed, and they are not allowed to
be: `totalsize` is what `PlatformInfo.dtbSize` carries and what the device tree
reclaim hands back to the buddy allocator, so a trimmed copy with a rewritten
header would no longer be the blob the kernel actually boots on. It would also
weaken the mutation oracle, which sizes its guard pages from the declared
extent.
