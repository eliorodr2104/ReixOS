import Testing
import ReixABI
@testable import ReixFS

@Suite("Where metadata trust ends", .serialized)
struct TrustAnchorTests {
    private enum Damage: CaseIterable { case stale, misdirected, rot }
    private static let block = Int(FSLayout.blockSize)

    @Test("a sum block contradicting a live table is refused by dirty and unsealed mounts")
    func sumContradiction() {
        for damage in Damage.allCases {
            for clean in [false, true] {
                withVolume { fs, disk, _ in
                    let home = fs.sumBlock(of: fs.plan.tableStart)
                    let old = disk.block(home)
                    changeRoot(&fs)
                    if clean { #expect(fs.unmount() == .ok); disk.unseal(fs.plan) }
                    damageSum(damage, home: home, old: old, fs: fs, disk: disk)
                    let writes = disk.writes
                    remount(disk) { again, found in
                        #expect(again == nil, "\(damage) clean \(clean)")
                        #expect(isCorrupt(found), "\(found)")
                    }
                    #expect(disk.writes == writes)
                }
            }
        }
    }

    @Test("known sum blocks that changed are refused by both scrubs and after a sealed mount")
    func knownSumRefusal() {
        for damage in Damage.allCases {
            for sealed in [false, true] {
                for depth in [FileSystem<MemoryDisk>.Scrub.everything, .data] {
                    withVolume { fs, disk, _ in
                        let home = fs.sumBlock(of: fs.plan.tableStart)
                        let old = disk.block(home)
                        changeRoot(&fs)
                        if sealed { #expect(fs.unmount() == .ok) }
                        damageSum(damage, home: home, old: old, fs: fs, disk: disk)
                        fs.dropCache()
                        if sealed {
                            remount(disk) { again, found in
                                guard var again else { Issue.record("\(found)"); return }
                                let writes = disk.writes
                                let findings = again.scan(depth)
                                #expect(!findings.complete && !findings.safeToServe, "\(damage)")
                                #expect(again.corrupted)
                                #expect(disk.writes == writes)
                            }
                        } else {
                            let writes = disk.writes
                            let findings = fs.scan(depth)
                            #expect(!findings.complete && !findings.safeToServe, "\(damage)")
                            #expect(fs.corrupted)
                            #expect(disk.writes == writes)
                        }
                    }
                }
            }
        }
    }

    @Test("an unused sum slot has no dirty-mount anchor and a scrub does not visit unused sum pages")
    func unusedSumHasNoAnchor() {
        for damage in Damage.allCases {
            for clean in [false, true] {
                withVolume { fs, disk, _ in
                    let home = fs.plan.dataStart - 1
                    let old = disk.block(home)
                    #expect(fs.readBlock(home, into: fs.metaBuffer) == .ok)
                    fs.metaBuffer.storeBytes(of: UInt32(0x12345678), toByteOffset: 200, as: UInt32.self)
                    #expect(fs.begin() == .ok)
                    #expect(fs.finish(fs.stageStructuralBlock(home, from: fs.metaBuffer)) == .ok)
                    if clean { #expect(fs.unmount() == .ok) }
                    switch damage {
                        case .stale: disk.put(old, block: home)
                        case .misdirected: disk.put(disk.block(home - 1), block: home)
                        case .rot:
                            let at = Int(home) * Self.block + 201
                            disk.poke(disk.byte(at: at) ^ 1, at: at)
                    }
                    remount(disk) { again, found in
                        guard var again else { Issue.record("\(damage): \(found)"); return }
                        again.dropCache()
                        #expect(again.scan(.data).safeToServe)
                        again.dropCache()
                        let status = again.readBlock(home, into: again.metaBuffer)
                        #expect(status == (clean ? .quarantined : .ok), "\(damage) clean \(clean)")
                    }
                }
            }
        }
    }

    @Test("a dirty mount derives a stale, misdirected or rotted bitmap from the table")
    func bitmapIsDerived() {
        for damage in Damage.allCases {
            withBitmapDamage(damage) { _, disk, home, expected in
                remount(disk) { again, found in
                    guard var again else { Issue.record("\(damage): \(found)"); return }
                    #expect(again.wasDirty)
                    #expect(disk.block(home) == expected)
                    let findings = again.scan(.data)
                    #expect(findings.complete && findings.safeToServe)
                    #expect(findings.damagedData == 0)
                }
            }
        }
    }

    @Test("a clean mount refuses a changed bitmap and live scrubs stop without writing")
    func bitmapIsRefusedWhenKnown() {
        for damage in Damage.allCases {
            for depth in [FileSystem<MemoryDisk>.Scrub.blocks, .everything, .data] {
                withBitmapDamage(damage) { fs, disk, _, _ in
                    let writes = disk.writes
                    let findings = fs.scan(depth)
                    #expect(!findings.complete && !findings.safeToServe)
                    #expect(fs.corrupted)
                    #expect(fs.repair(findings) == .notFound)
                    #expect(disk.writes == writes)
                }
            }
            for sealed in [false, true] {
                withBitmapDamage(damage, clean: true) { fs, disk, _, _ in
                    if !sealed { disk.unseal(fs.plan) }
                    let writes = disk.writes
                    remount(disk) { again, found in
                        #expect(again == nil)
                        #expect(isCorrupt(found), "\(damage): \(found)")
                    }
                    #expect(disk.writes == writes)
                }
            }
        }
    }

    private func withBitmapDamage(_ damage: Damage, clean: Bool = false,
        _ body: (inout FileSystem<MemoryDisk>, MemoryDisk, UInt32, [UInt8]) -> Void) {
        withVolume { fs, disk, file in
            let home = fs.plan.bitmapStart
            let old = disk.block(home)
            let page = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
            defer { page.deallocate() }
            page.initializeMemory(as: UInt8.self, repeating: 0xA5, count: Self.block)
            #expect(fs.write(file, at: FSLayout.blockSize, from: page, count: FSLayout.blockSize).status == .ok)
            let expected = disk.block(home)
            if clean { #expect(fs.unmount() == .ok) }
            switch damage {
                case .stale: disk.put(old, block: home)
                case .misdirected: disk.put(disk.block(fs.object(file)!.runs[0].start), block: home)
                case .rot:
                    let at = Int(home) * Self.block
                    disk.poke(disk.byte(at: at) ^ 1, at: at)
            }
            fs.dropCache()
            body(&fs, disk, home, expected)
        }
    }

    private func damageSum(_ damage: Damage, home: UInt32, old: [UInt8],
                           fs: FileSystem<MemoryDisk>, disk: MemoryDisk) {
        switch damage {
            case .stale: disk.put(old, block: home)
            case .misdirected: disk.put(disk.block(home + 1), block: home)
            case .rot:
                let at = Int(home) * Self.block + fs.sumOffset(of: fs.plan.tableStart)
                disk.poke(disk.byte(at: at) ^ 1, at: at)
        }
    }

    private func changeRoot(_ fs: inout FileSystem<MemoryDisk>) {
        guard var root = fs.object(FSLayout.rootObject) else { Issue.record("root"); return }
        root.created += 1
        #expect(fs.begin() == .ok)
        #expect(fs.finish(fs.store(root, at: FSLayout.rootObject)) == .ok)
    }

    private func withVolume(_ body: (inout FileSystem<MemoryDisk>, MemoryDisk, UInt32) -> Void) {
        let disk = MemoryDisk(sectors: 32768)
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }
        guard var fs = FileSystem.format(disk, scratch: space).disk else { Issue.record("format"); return }
        let name: StaticString = "a.bin"
        let made = fs.create(UnsafeRawPointer(name.utf8Start), length: name.utf8CodeUnitCount,
                             kind: .file, in: FSLayout.rootObject)
        guard made.status == .ok else { Issue.record("create"); return }
        let page = UnsafeMutableRawPointer.allocate(byteCount: Self.block, alignment: 8)
        defer { page.deallocate() }
        page.initializeMemory(as: UInt8.self, repeating: 0x5A, count: Self.block)
        #expect(fs.write(made.object, at: 0, from: page, count: FSLayout.blockSize).status == .ok)
        body(&fs, disk, made.object)
    }

    private func remount(_ disk: MemoryDisk, _ body: (FileSystem<MemoryDisk>?, FSMount) -> Void) {
        let space = UnsafeMutableRawPointer.allocate(byteCount: FileSystem<MemoryDisk>.scratchBytes, alignment: 8)
        defer { space.deallocate() }
        let mounted = FileSystem.mount(disk, scratch: space)
        body(mounted.disk, mounted.found)
    }

    private func isCorrupt(_ found: FSMount) -> Bool {
        if case .corrupt = found { return true }
        return false
    }
}
