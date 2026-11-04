//
//  ELFSegmentCopyTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport
import KernelHostShims

extension KernelPolicyTestRoot {
@Suite("Private ELF copy steps", .serialized)
struct ELFSegmentCopyTests {

    @Test("an unaligned segment crosses three pages with a window after every copy")
    func unalignedCopy() {
        let base = UserSpaceLayout.elfBaseTypical + 17
        let payload = (0..<8195).map { UInt8(truncatingIfNeeded: $0) }
        PreemptionSpans.reset()
        host_set_counter_frequency(0)
        defer { PreemptionSpans.reset() }

        let opened = withLoadedELFImage([
            ELFSegmentFixture(flags: 0x6, virtual: base, memorySize: 8220, payload: payload)
        ], layout: .unaligned) { image in
            guard case .success = image.result else {
                Issue.record("the unaligned segment was refused")
                return
            }
            for index in payload.indices {
                #expect(image.byte(at: base + UInt64(index)) == payload[index])
            }
            #expect(image.byte(at: base - 1) == 0)
            #expect(image.byte(at: base + UInt64(payload.count)) == 0)
            #expect(PreemptionSpans.span(of: ProcessCreation.self).checkpoints == 6)
        }
        #expect(opened)
    }

    @Test("a missing mapping or short read refuses without advancing or staging code")
    func copyRefusals() {
        for refusal in 0...1 {
            withCopyFixture { ram, _, resources, fileSystem, handle, fileSize in
                let base = UserSpaceLayout.elfBaseTypical
                let cursor = refusal == 0 ? base + 2 * UserSpaceLayout.pageSize : base
                if refusal == 1 { try? fileSystem.pointee.seek(handle: handle, to: fileSize - 1) }
                var work = ELFSegmentCopy(
                    fileSystem: fileSystem, handle: handle, vmm: ram.vmm,
                    root: resources.addressSpace!.rootTablePhysical, code: true,
                    cursor: cursor, remaining: 2
                )
                mmu_trace_reset(nil)
                defer { mmu_trace_reset(nil) }
                expectRefusal(&work)
                #expect(work.cursor == cursor && work.remaining == 2)
                #expect(mmuCalls().isEmpty)
            }
        }
    }

    @Test("a failed read after one completed page unwinds the whole private image")
    func failedReadAfterPrefix() {
        withCopyFixture { ram, _, resources, fileSystem, handle, _ in
            let base = UserSpaceLayout.elfBaseTypical
            let page = UserSpaceLayout.pageSize
            var work = ELFSegmentCopy(
                fileSystem: fileSystem, handle: handle, vmm: ram.vmm,
                root: resources.addressSpace!.rootTablePhysical, code: true,
                cursor: base, remaining: 2 * page
            )
            withCacheType(cortexA53CacheType) {
                #expect((try? work.step()) == .more)
                #expect(work.cursor == base + page && work.remaining == page)
                if let physical = ram.vmm.pointee.physicalAddressOf(rootTable: work.root, virtual: base) {
                    let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(physical)
                    #expect(bytes[0] == 0x6E && bytes[Int(page) - 1] == 0x6E)
                } else { Issue.record("the completed page lost its mapping") }
                try? fileSystem.pointee.close(handle: handle)
                mmu_trace_reset(nil)
                defer { mmu_trace_reset(nil) }
                expectRefusal(&work)
                #expect(work.cursor == base + page && work.remaining == page)
                #expect(mmuCalls().isEmpty)
            }
        }
    }

    private func expectRefusal(_ work: inout ELFSegmentCopy) {
        do throws(ElfError) {
            _ = try work.step()
            Issue.record("a refused copy reported success")
        } catch {
            if case .malformedLayout = error {} else { Issue.record("unexpected refusal: \(error)") }
        }
    }

    private func withCopyFixture(
        _ body: (HostRAM, UnsafeMutablePointer<ProcessManager>, ProcessPreparation.Resources,
                 UnsafeMutablePointer<TarFileSystem>, FileHandle, UInt64) -> Void
    ) {
        withProcessManager(pages: 128) { ram, heap, manager in
            let held = ram.ppm.pointee.allocatedPages
            let live = heap.pointee.metricsLiveBytes
            var resources = ProcessPreparation.Resources()
            withUnsafeMutablePointer(to: &resources) { storage in
                #expect(throws: Never.self) {
                    _ = try Preemption.run(ProcessCreation.self, ProcessPreparation(
                        heap: heap, vmm: ram.vmm, ppm: ram.ppm, resources: storage,
                        frameLimit: .max, makeContext: false
                    ))
                }
            }
            guard let space = resources.addressSpace, let metadata = resources.metadata,
                  let vma = space.vmaManager else { Issue.record("the image was not prepared"); return }
            let base = UserSpaceLayout.elfBaseTypical
            let size = 2 * UserSpaceLayout.pageSize
            #expect(throws: Never.self) {
                try vma.pointee.registerRegion(
                    start: base, size: size, permissions: [.read, .write, .user],
                    backing: .anonymous, flags: .none, memoryType: .normal
                )
                _ = try Preemption.run(ProcessCreation.self, ELFPageFill(
                    addressSpace: space, vmm: ram.vmm, ppm: ram.ppm,
                    budget: metadata.pointee.budget, permissions: [.read, .write, .user],
                    cursor: base, end: base + size
                ))
            }
            let opened = withLoadedELFImage([
                ELFSegmentFixture(flags: 0x6, virtual: base, memorySize: size,
                                  payload: Array(repeating: 0x6E, count: Int(size)))
            ], layout: .unaligned) { image in
                let fileSystem = UnsafeMutablePointer<TarFileSystem>.allocate(capacity: 1)
                fileSystem.initialize(to: TarFileSystem())
                defer { fileSystem.deinitialize(count: 1); fileSystem.deallocate() }
                guard let handle = try? fileSystem.pointee.open(path: "elf", flags: [.read]) else {
                    Issue.record("the source image would not open")
                    return
                }
                defer { try? fileSystem.pointee.close(handle: handle) }
                try? fileSystem.pointee.seek(handle: handle, to: image.fileOffset(of: 0))
                body(ram, manager, resources, fileSystem, handle, image.fileSize)
            }
            #expect(opened)
            manager.pointee.discardPreparation(resources)
            #expect(heap.pointee.metricsLiveBytes == live)
            #expect(ram.ppm.pointee.allocatedPages == held)
        }
    }
}
}
