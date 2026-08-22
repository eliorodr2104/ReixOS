# Tar corpus

One ustar archive in the exact layout the real initrd has, written by the
repo's own packer rather than by `/usr/bin/tar`. It is what the corpus and
mutation suites walk (`Tests/KernelPolicyTests/TarArchiveCorpusTests.swift`,
`Tests/KernelPolicyTests/TarArchiveMutationTests.swift`).

## Tooling

| | |
|---|---|
| Packer | `Plugins/reix/UstarWriter.swift`, the same source `reix pack` uses |
| Compiler | `~/.swiftly/bin/swiftc`, Apple Swift version 6.3.2 (swift-6.3.2-RELEASE) |
| Host | macOS 26 (Darwin 25.5.0), arm64 |
| Captured | 2026-08-09 |

`UstarWriter` lives in a SwiftPM *plugin* target, which no test target is
allowed to depend on, so the fixture is produced ahead of time by compiling
that one file together with a throwaway driver. The driver is not checked in;
it is reproduced in full below, and `UstarWriter.write` is deterministic
(`mtime` is hard-coded to 0 for exactly this reason).

    // main.swift, in the scratchpad
    import Foundation

    func pattern(_ count: Int, seed: UInt8) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for i in 0..<count {
            bytes.append(UInt8((i * 37 + Int(seed)) & 0xFF))
        }
        return Data(bytes)
    }

    let members: [UstarWriter.Member] = [
        .init(name: "alpha.txt",     data: Data("alpha bytes".utf8)),
        .init(name: "al",            data: Data("prefix".utf8)),
        .init(name: "alpha.txt.bak", data: Data("suffixed".utf8)),
        .init(name: "beta.bin",      data: pattern(4096, seed: 1)),
        .init(name: "empty.dat",     data: Data()),
        .init(name: "gamma.bin",     data: pattern(600, seed: 9)),
    ]

    let archive = UstarWriter.write(members: members)
    guard UstarWriter.verifyPageAlignment(archive) else {
        FileHandle.standardError.write(Data("ustar: alignment verification failed\n".utf8))
        exit(1)
    }
    try archive.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

    $ swiftc -O -o packfixture Plugins/reix/UstarWriter.swift main.swift
    $ ./packfixture Tests/Fixtures/tar/corpus.tar

## Artifact

`corpus.tar`, 30720 bytes,
sha256 `13add50c4c28371579f13cfd378dd0020a238977e27c9820f79fc6958de92b66`.

    hdr@    0  data@  512  size=3072  @pad
    hdr@ 3584  data@ 4096  size=  11  alpha.txt
    hdr@ 4608  data@ 5120  size=2560  @pad
    hdr@ 7680  data@ 8192  size=   6  al
    hdr@ 8704  data@ 9216  size=2560  @pad
    hdr@11776  data@12288  size=   8  alpha.txt.bak
    hdr@12800  data@13312  size=2560  @pad
    hdr@15872  data@16384  size=4096  beta.bin
    hdr@20480  data@20992  size=3072  @pad
    hdr@24064  data@24576  size=   0  empty.dat
    hdr@24576  data@25088  size=3072  @pad
    hdr@28160  data@28672  size= 600  gamma.bin
    28672+600 .. 30720     two zero blocks: end-of-archive

Every real member's data starts on a 4096 boundary, which is what lets the ELF
loader map segments straight out of the image; the `@pad` fillers are how
`UstarWriter` buys that alignment, and they are well-formed members so the
kernel's walk steps over them like any other entry.

## Why these members

The names are chosen against `TarFileSystem.isFileSection`, which has to reject
a prefix and an extension as firmly as it rejects an unrelated name:

* `alpha.txt` and `al`: `al` is a proper prefix of `alpha.txt`, and it comes
  *first* in the archive, so a walk that stopped at a prefix match would hand
  back the wrong member.
* `alpha.txt.bak`: `alpha.txt` is a proper prefix of it, the other direction.
* `empty.dat`: a zero-length member, the boundary case for the size field and
  for `isResident(base:size:)`.
* `beta.bin` and `gamma.bin`: one exactly a page, one not a multiple of 512,
  so the block padding at the end of a member is exercised both ways.

A member whose name fills all 100 bytes of the field with no NUL, the other
branch of the exact-match test, cannot be produced here: `UstarWriter.field`
refuses a name that does not leave room for a terminator. That case is built
byte by byte in `Tests/Support/TarCorpusFixtures.swift` instead.
