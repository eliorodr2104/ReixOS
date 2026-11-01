//
//  TaskMapFillTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import KernelTestSupport

/// `mapTaskAnonymous` as one `TaskMapAnonymous` run of `TaskMapFill` steps.
///
/// The success path, the zeroing and the budget refusal are covered where they
/// always were, `EL0PageZeroingTests` and `FrameBudgetTests`. This suite owns
/// what the steps added: the windows, and the two failures a step undoes
/// itself before the caller's rollback runs.
extension KernelPolicyTestRoot {
@Suite("Task map fill", .serialized)
struct TaskMapFillTests {

    private static let page = UserSpaceLayout.pageSize


    /// On the host the budget is zero, so every probe opens a window: one per
    /// step that leaves work behind.
    @Test("a task map runs as one region run that opens a window after every page")
    func fillOpensWindows() {
        withSuspendedTask(pages: 256) { ram, manager, task in
            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            let base = UserSpaceLayout.elfBaseTypical

            #expect(manager.pointee.mapTaskAnonymous(task.control, at: base, pages: 64) == .ok)

            let span = PreemptionSpans.span(of: TaskMapAnonymous.self)
            #expect(span.checkpoints == 63)
            #expect(span.name.description == "[TMAP]")

            guard let vma = task.process.pointee.addressSpace.vmaManager else {
                Issue.record("the task lost its VMA manager")
                return
            }
            for index in 0..<64 {
                #expect(vma.pointee.isPageMapped(at: base + UInt64(index) * Self.page))
            }
            #expect(vma.pointee.residentPages == 64)
        }
    }


    @Test("a one-page map takes one step and opens no window")
    func onePage() {
        withSuspendedTask(pages: 128) { ram, manager, task in
            PreemptionSpans.reset()
            defer { PreemptionSpans.reset() }

            #expect(manager.pointee.mapTaskAnonymous(
                task.control,
                at   : UserSpaceLayout.elfBaseTypical,
                pages: 1
            ) == .ok)

            #expect(PreemptionSpans.span(of: TaskMapAnonymous.self).checkpoints == 0)
        }
    }


    /// Frames run out part way: the step that cannot take one gives its charge
    /// back, and the rollback gives back every page before it.
    @Test("running out of frames part way gives back every page and every charge")
    func outOfFramesPartWay() {
        withSuspendedTask(pages: 160) { ram, manager, task in
            let child = task.process
            raiseLimit(of: child)

            let chargedBefore = charged(child)
            let heldBefore    = ram.ppm.pointee.allocatedPages
            let base          = UserSpaceLayout.elfBaseTypical

            #expect(manager.pointee.mapTaskAnonymous(task.control, at: base, pages: 512) == .outOfMemory)

            #expect(charged(child) == chargedBefore)
            #expect(ram.ppm.pointee.allocatedPages <= heldBefore)

            guard let vma = child.pointee.addressSpace.vmaManager else {
                Issue.record("the task lost its VMA manager")
                return
            }
            #expect(!vma.pointee.isPageMapped(at: base))
            #expect(vma.pointee.residentPages == 0)
        }
    }


    /// A page already mapped where the step installs makes the install refuse.
    /// Driven one step at a time, so what is measured is the step's own undo
    /// and not the caller's rollback after it.
    @Test("an install that fails gives back the page and the charge the step took")
    func installFailure() {
        withSuspendedTask(pages: 128) { ram, manager, task in
            let child = task.process
            raiseLimit(of: child)

            guard let vma = child.pointee.addressSpace.vmaManager,
                  let occupant = try? ram.ppm.pointee.alloc(Int(Self.page))
            else {
                Issue.record("could not stage the occupied page")
                return
            }

            let address = UserSpaceLayout.elfBaseTypical
            let root    = child.pointee.addressSpace.rootTablePhysical

            #expect(throws: Never.self) {
                try ram.vmm.pointee.installUserPage(
                    rootTable: root,
                    asid     : child.pointee.addressSpace.asid,
                    virtual  : address,
                    physical : occupant.address,
                    flags    : VMAPermissions([.read, .write, .user]).toPageFlags(),
                    type     : .normal
                )
            }

            let chargedBefore = charged(child)
            let heldBefore    = ram.ppm.pointee.allocatedPages

            var fill = TaskMapFill(
                ppm   : ram.ppm,
                vmm   : ram.vmm,
                vma   : vma,
                root  : root,
                budget: child.pointee.metadata.pointee.budget,
                start : address,
                end   : address + Self.page
            )

            do throws(PPMError) {
                _ = try fill.step()
                Issue.record("the step installed over a mapped page")
            } catch {
                if case .pageAlreadyMapped = error {} else { Issue.record("refused with \(error)") }
            }

            #expect(charged(child) == chargedBefore)
            #expect(ram.ppm.pointee.allocatedPages == heldBefore)
            #expect(vma.pointee.residentPages == 0)
        }
    }


    @Test("a step past the end of its range does nothing and says done")
    func stepPastTheEnd() {
        withSuspendedTask(pages: 128) { ram, _, task in
            let child = task.process

            guard let vma = child.pointee.addressSpace.vmaManager else {
                Issue.record("the task lost its VMA manager")
                return
            }

            let address    = UserSpaceLayout.elfBaseTypical
            let heldBefore = ram.ppm.pointee.allocatedPages

            var fill = TaskMapFill(
                ppm   : ram.ppm,
                vmm   : ram.vmm,
                vma   : vma,
                root  : child.pointee.addressSpace.rootTablePhysical,
                budget: child.pointee.metadata.pointee.budget,
                start : address,
                end   : address
            )

            let progress = try? fill.step()
            #expect(progress == .done)
            #expect(ram.ppm.pointee.allocatedPages == heldBefore)
        }
    }


    // MARK: - Fixtures

    private func withSuspendedTask(
        pages : Int,
        _ body: (HostRAM, UnsafeMutablePointer<ProcessManager>, (control: TaskControl, process: UnsafeMutablePointer<Process>)) -> Void
    ) {
        withProcessManager(pages: pages) { ram, _, manager in
            TaskRegistry.resetForTesting()
            defer { TaskRegistry.resetForTesting() }

            guard let owner = try? manager.pointee.spawnProcess(),
                  let task  = manager.pointee.createSuspendedTask(ownedBy: owner)
            else {
                Issue.record("could not create the suspended task")
                return
            }

            body(ram, manager, task)
        }
    }


    private func charged(_ process: UnsafeMutablePointer<Process>) -> UInt32 {
        process.pointee.metadata.pointee.budget.pointee.charged
    }


    /// Out of the way, so the PPM and not the budget is what runs out.
    private func raiseLimit(of process: UnsafeMutablePointer<Process>) {
        process.pointee.metadata.pointee.budget.pointee.limit = .max
    }
}
}
