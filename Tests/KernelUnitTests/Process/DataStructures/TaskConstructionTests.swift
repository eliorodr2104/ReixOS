//
//  TaskConstructionTests.swift
//  ReixOS
//

import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// The rules a task's construction object enforces on its own: the region
/// table, sealing, write coverage, the context check and readiness, plus the
/// layout the registry split rests on.
@Suite("Task construction object")
struct TaskConstructionTests {

    private static let page  = UserSpaceLayout.pageSize
    private static let text  = UserSpaceLayout.elfBaseTypical
    private static let stack = UserSpaceLayout.stackTop - UserSpaceLayout.pageSize


    // MARK: - Layout

    @Test("the live record fits 32 bytes and the construction one 1 KiB bucket")
    func layout() {
        // Regression: the record carried the region table and was 816 bytes a
        // slot, 26 KiB of static data whether or not any task was configuring.
        #expect(MemoryLayout<TaskRecord>.size <= 32)
        #expect(MemoryLayout<TaskRecord?>.stride == 32)
        #expect(MemoryLayout<TaskConstruction>.size > 512)
        #expect(MemoryLayout<TaskConstruction>.size <= 1024)
    }


    @Test("zeroed memory reads as an empty construction")
    func zeroIsEmpty() {
        let construction = allocateZeroedStorage(TaskConstruction.self)
        defer { UnsafeMutableRawPointer(construction).deallocate() }

        #expect(construction.pointee.budget == nil)
        #expect(construction.pointee.regionCount == 0)
        #expect(!construction.pointee.contextSet)
        #expect(!Self.isReady(construction))
        #expect(!Self.permitsWrite(construction, Self.text, end: Self.text + 1))
    }


    // MARK: - Regions

    @Test("the table takes exactly the ABI's region count and refuses one more")
    func regionLimit() {
        let construction = Self.empty()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        let limit = Int(TaskABI.maximumRegions)

        for index in 0..<limit {
            let start = Self.text + UInt64(index) * Self.page
            #expect(Self.append(construction, start, end: start + Self.page))
        }
        #expect(Int(construction.pointee.regionCount) == limit)

        let past = Self.text + UInt64(limit) * Self.page
        #expect(!Self.append(construction, past, end: past + Self.page))
        #expect(Int(construction.pointee.regionCount) == limit)

        let last = construction.pointee.regions[limit - 1]
        #expect(last.start == Self.text + UInt64(limit - 1) * Self.page)
        #expect(last.permissions == [.read, .write])
        #expect(!last.sealed)
    }


    @Test("a seal names one exact region and takes it once")
    func sealIsExactAndOnce() {
        let construction = Self.empty()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        #expect(Self.append(construction, Self.text, end: Self.text + 2 * Self.page))

        #expect(!Self.seal(construction, Self.text + Self.page, end: Self.text + 2 * Self.page, permissions: [.read]))
        #expect(!Self.seal(construction, Self.text, end: Self.text + Self.page, permissions: [.read]))
        #expect(!Self.seal(construction, Self.stack, end: Self.stack + Self.page, permissions: [.read]))
        #expect(!construction.pointee.regions[0].sealed)

        #expect(Self.seal(construction, Self.text, end: Self.text + 2 * Self.page, permissions: [.read, .execute]))
        #expect(construction.pointee.regions[0].sealed)
        #expect(construction.pointee.regions[0].permissions == [.read, .execute])

        #expect(!Self.seal(construction, Self.text, end: Self.text + 2 * Self.page, permissions: [.read, .write]))
        #expect(construction.pointee.regions[0].permissions == [.read, .execute])
    }


    @Test("a write must be covered end to end by unsealed writable regions")
    func writeCoverage() {
        let construction = Self.empty()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        let a = Self.text
        #expect(Self.append(construction, a, end: a + Self.page))
        #expect(Self.append(construction, a + Self.page, end: a + 2 * Self.page))
        #expect(Self.append(construction, a + 3 * Self.page, end: a + 4 * Self.page))

        #expect(Self.permitsWrite(construction, a, end: a + Self.page))
        #expect(Self.permitsWrite(construction, a + 10, end: a + 20))
        #expect(Self.permitsWrite(construction, a, end: a + 2 * Self.page))

        #expect(!Self.permitsWrite(construction, a, end: a))
        #expect(!Self.permitsWrite(construction, a + 1, end: a))
        #expect(!Self.permitsWrite(construction, a - 1, end: a + 1))
        #expect(!Self.permitsWrite(construction, a, end: a + 2 * Self.page + 1))
        #expect(!Self.permitsWrite(construction, a, end: a + 4 * Self.page))

        #expect(Self.seal(construction, a + Self.page, end: a + 2 * Self.page, permissions: [.read, .write]))
        #expect(Self.permitsWrite(construction, a, end: a + Self.page))
        #expect(!Self.permitsWrite(construction, a, end: a + Self.page + 1))
        #expect(!Self.permitsWrite(construction, a + Self.page, end: a + Self.page + 1))
    }


    // MARK: - Context

    @Test("the context names an executable entry, a writable stack and a break past the image")
    func contextRules() {
        let construction = Self.sealedImage()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        let brk = Self.text + Self.page

        #expect(Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: brk))
        #expect(Self.canSetContext(construction, Self.text + Self.page - 4, stack: Self.stack + 16, programBreak: brk))
        #expect(Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: UserSpaceLayout.mmapMin - Self.page))

        #expect(!Self.canSetContext(construction, Self.text + Self.page, stack: UserSpaceLayout.stackTop, programBreak: brk))
        #expect(!Self.canSetContext(construction, Self.stack, stack: UserSpaceLayout.stackTop, programBreak: brk))
        #expect(!Self.canSetContext(construction, Self.text, stack: Self.stack, programBreak: brk))
        #expect(!Self.canSetContext(construction, Self.text, stack: Self.text + 16, programBreak: brk))
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.userMin, programBreak: brk))
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: brk + 1))
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: brk - Self.page))
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: UserSpaceLayout.mmapMin))
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: UserSpaceLayout.userMin - Self.page))
    }


    @Test("a stack in a writable executable region is refused")
    func contextRefusesExecutableStack() {
        let construction = Self.sealedImage()
        defer { UnsafeMutableRawPointer(construction).deallocate() }

        // `sealTaskRegion` never seals W+X; this is the check behind it.
        construction.pointee.regions[1].permissions = [.read, .write, .execute]
        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: Self.text + Self.page))
    }


    @Test("an unsealed region counts for nothing in the context check")
    func contextIgnoresUnsealed() {
        let construction = Self.empty()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        #expect(Self.append(construction, Self.text, end: Self.text + Self.page))
        #expect(Self.append(construction, Self.stack, end: Self.stack + Self.page))
        #expect(Self.seal(construction, Self.stack, end: Self.stack + Self.page, permissions: [.read, .write]))

        #expect(!Self.canSetContext(construction, Self.text, stack: UserSpaceLayout.stackTop, programBreak: Self.text + Self.page))
    }


    @Test("ready means a context and every region sealed, and at least one region")
    func readiness() {
        let construction = Self.empty()
        defer { UnsafeMutableRawPointer(construction).deallocate() }
        construction.pointee.contextSet = true
        #expect(!Self.isReady(construction))

        #expect(Self.append(construction, Self.text, end: Self.text + Self.page))
        #expect(Self.append(construction, Self.stack, end: Self.stack + Self.page))
        #expect(Self.seal(construction, Self.text, end: Self.text + Self.page, permissions: [.read, .execute]))
        #expect(!Self.isReady(construction))

        #expect(Self.seal(construction, Self.stack, end: Self.stack + Self.page, permissions: [.read, .write]))
        #expect(Self.isReady(construction))

        construction.pointee.contextSet = false
        #expect(!Self.isReady(construction))
    }


    // MARK: - Fixtures

    /// A zeroed cell, the way `ProcessManager` builds one, freed by the caller.
    private static func empty() -> UnsafeMutablePointer<TaskConstruction> {
        allocateZeroedStorage(TaskConstruction.self)
    }

    /// Out of `#expect`, which cannot reach a mutating member through `pointee`.
    private static func append(
        _ construction: UnsafeMutablePointer<TaskConstruction>,
        _ start       : VirtualAddress,
        end           : VirtualAddress
    ) -> Bool {
        construction.pointee.append(start: start, end: end)
    }

    private static func permitsWrite(
        _ construction: UnsafeMutablePointer<TaskConstruction>,
        _ start       : VirtualAddress,
        end           : VirtualAddress
    ) -> Bool {
        construction.pointee.permitsWrite(start: start, end: end)
    }

    private static func canSetContext(
        _ construction: UnsafeMutablePointer<TaskConstruction>,
        _ entry       : VirtualAddress,
        stack         : VirtualAddress,
        programBreak  : VirtualAddress
    ) -> Bool {
        construction.pointee.canSetContext(entry: entry, stack: stack, programBreak: programBreak)
    }

    private static func isReady(_ construction: UnsafeMutablePointer<TaskConstruction>) -> Bool {
        construction.pointee.isReady
    }

    private static func seal(
        _ construction: UnsafeMutablePointer<TaskConstruction>,
        _ start       : VirtualAddress,
        end           : VirtualAddress,
        permissions   : TaskMemoryPermissions
    ) -> Bool {
        construction.pointee.seal(start: start, end: end, permissions: permissions)
    }

    /// One executable text page and one writable stack page, both sealed.
    private static func sealedImage() -> UnsafeMutablePointer<TaskConstruction> {
        let construction = empty()
        _ = construction.pointee.append(start: text, end: text + page)
        _ = construction.pointee.append(start: stack, end: stack + page)
        _ = construction.pointee.seal(start: text, end: text + page, permissions: [.read, .execute])
        _ = construction.pointee.seal(start: stack, end: stack + page, permissions: [.read, .write])
        return construction
    }
}
