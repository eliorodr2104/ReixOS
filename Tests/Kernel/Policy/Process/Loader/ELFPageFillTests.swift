//
//  ELFPageFillTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

extension KernelPolicyTestRoot {
@Suite("Private ELF page steps", .serialized)
struct ELFPageFillTests {

    @Test("a step fills one zeroed page and an exhausted run changes nothing")
    func onePagePerStep() {
        withProcessManager(pages: 128) { ram, _, manager in
            guard let child = try? manager.pointee.spawnProcess() else {
                Issue.record("could not prepare the image")
                return
            }
            let budget = child.pointee.metadata.pointee.budget!
            let base = UserSpaceLayout.elfBaseTypical
            let page = UserSpaceLayout.pageSize
            var work = ELFPageFill(
                addressSpace: child.pointee.addressSpace, vmm: ram.vmm, ppm: ram.ppm,
                budget: budget, permissions: [.read, .write, .user], cursor: base, end: base + 2 * page
            )
            #expect((try? work.step()) == .more)
            #expect(work.cursor == base + page)
            let first = ram.vmm.pointee.physicalAddressOf(rootTable: child.pointee.addressSpace.rootTablePhysical, virtual: base)
            #expect(first != nil)
            #expect(ram.vmm.pointee.physicalAddressOf(rootTable: child.pointee.addressSpace.rootTablePhysical, virtual: base + page) == nil)
            if let first {
                let bytes: UnsafeMutablePointer<UInt8> = ram.vmm.pointee.physToVirt(first)
                #expect(UnsafeBufferPointer(start: bytes, count: Int(page)).allSatisfy { $0 == 0 })
            }
            let charged = budget.pointee.charged
            #expect((try? work.step()) == .more)
            #expect(budget.pointee.charged == charged + 1)
            let held = ram.ppm.pointee.allocatedPages
            #expect((try? work.step()) == .done)
            #expect((try? work.step()) == .done)
            #expect(ram.ppm.pointee.allocatedPages == held)
            #expect(budget.pointee.charged == charged + 1)
        }
    }

    @Test("budget, frame and install refusals leave the cursor, charge and pages unchanged")
    func refusedPage() {
        for refusal in 0...2 {
            withProcessManager(pages: 128) { ram, _, manager in
                guard let child = try? manager.pointee.spawnProcess() else {
                    Issue.record("could not prepare the image")
                    return
                }
                let budget = child.pointee.metadata.pointee.budget!
                budget.pointee.limit = .max
                let base = UserSpaceLayout.elfBaseTypical
                var work = ELFPageFill(
                    addressSpace: child.pointee.addressSpace, vmm: ram.vmm, ppm: ram.ppm,
                    budget: budget, permissions: [.read, .write, .user], cursor: base,
                    end: base + UserSpaceLayout.pageSize
                )
                if refusal == 0 {
                    budget.pointee.limit = budget.pointee.charged
                } else if refusal == 1 {
                    while (try? ram.ppm.pointee.alloc(4096)) != nil {}
                } else {
                    var occupant = work
                    #expect((try? occupant.step()) == .more)
                }
                let charged = budget.pointee.charged
                let held = ram.ppm.pointee.allocatedPages
                do throws(ElfError) {
                    _ = try work.step()
                    Issue.record("a refused page was filled")
                } catch {}
                #expect(work.cursor == base)
                #expect(budget.pointee.charged == charged)
                #expect(ram.ppm.pointee.allocatedPages == held)
            }
        }
    }
}
}
