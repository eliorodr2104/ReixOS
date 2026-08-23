import Testing
@testable import Kernel
import ReixABI
import KernelTestSupport

/// The bound on a device register access.
///
/// This is the check that lets a window smaller than a page be handed out at
/// all. The memory unit cannot express it: its smallest unit is the 4 KiB page,
/// and eight virtio slots share one. So the extent the capability names is
/// enforced here, per access, and if it is enforced loosely it is not enforced:
/// one word past the end is another device's register.
@Suite("Device register bounds", .serialized)
struct DeviceAccessTests {

    private static let windowBase: UInt64 = 0x0A00_0000
    private static let windowSize: UInt64 = 0x200      // one virtio slot

    private func withHolder(
        rights: CapRights = [.read, .write],
        size  : UInt64 = DeviceAccessTests.windowSize,
        _ body: (UnsafeMutablePointer<Process>, UInt32) -> Void
    ) {
        let metadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
        metadata.initialize(to: ProcessMetadata())
        defer { metadata.deinitialize(count: 1); metadata.deallocate() }

        let process = makeProcess(pid: 3)
        defer { destroyProcess(process) }
        process.pointee.metadata = metadata

        guard let handle = metadata.pointee.capsTable.install(
            Capability(
                target: .device(DeviceRegion(address: Self.windowBase, size: size)),
                badge : Badge(0),
                rights: rights
            )
        ) else {
            Issue.record("could not install the device capability")
            return
        }

        body(process, handle)
    }

    private func address(
        _ process: UnsafeMutablePointer<Process>,
        _ handle : UInt32,
        _ offset : UInt64,
        _ right  : CapRights = .read
    ) -> UnsafeMutableRawPointer? {
        DeviceAccess.address(handle: UInt64(handle), offset: offset, needing: right, of: process)
    }


    @Test("an aligned offset inside the window resolves, and lands where it says")
    func insideResolves() {
        withHolder { process, handle in
            guard let first = address(process, handle, 0),
                  let second = address(process, handle, 4)
            else {
                Issue.record("an offset inside the window was refused")
                return
            }

            #expect(UInt(bitPattern: second) - UInt(bitPattern: first) == 4)

            // The last word that fits: offset 508 plus four bytes is exactly
            // the end of a 512-byte slot.
            #expect(address(process, handle, Self.windowSize - 4) != nil)
        }
    }


    @Test("one word past the end is refused, and that word is another device")
    func pastTheEndRefused() {
        withHolder { process, handle in
            #expect(address(process, handle, Self.windowSize) == nil)
            #expect(address(process, handle, Self.windowSize - 3) == nil)
            #expect(address(process, handle, Self.windowSize + 4) == nil)

            // The register at 0x200 into this window is register 0 of the next
            // virtio slot. Nothing about the page it shares makes it reachable.
            #expect(address(process, handle, 0x1000) == nil)
        }
    }


    @Test("an unaligned offset is refused rather than rounded")
    func unalignedRefused() {
        withHolder { process, handle in
            for offset in [UInt64(1), 2, 3, 5, 7, 509, 510, 511] {
                #expect(address(process, handle, offset) == nil)
            }
        }
    }


    @Test("an offset that would overflow the arithmetic is refused")
    func overflowRefused() {
        withHolder { process, handle in
            // `size - offset` underflows if the order of the checks is wrong,
            // and an underflowed bound accepts everything.
            #expect(address(process, handle, UInt64.max) == nil)
            #expect(address(process, handle, UInt64.max - 3) == nil)
            #expect(address(process, handle, 1 << 63) == nil)
        }
    }


    @Test("each direction needs its own right")
    func rightsAreSeparate() {
        withHolder(rights: [.read]) { process, handle in
            #expect(address(process, handle, 0, .read)  != nil)
            #expect(address(process, handle, 0, .write) == nil)
        }

        withHolder(rights: [.write]) { process, handle in
            #expect(address(process, handle, 0, .read)  == nil)
            #expect(address(process, handle, 0, .write) != nil)
        }
    }


    @Test("a handle that names something other than a device is refused")
    func onlyDeviceCapabilities() {
        let metadata = UnsafeMutablePointer<ProcessMetadata>.allocate(capacity: 1)
        metadata.initialize(to: ProcessMetadata())
        defer { metadata.deinitialize(count: 1); metadata.deallocate() }

        let process = makeProcess(pid: 4)
        defer { destroyProcess(process) }
        process.pointee.metadata = metadata

        let endpoint = UnsafeMutablePointer<Endpoint>.allocate(capacity: 1)
        endpoint.initialize(to: Endpoint(queue: LinkedList(head: nil, tail: nil)))
        defer { endpoint.deinitialize(count: 1); endpoint.deallocate() }

        let handle = metadata.pointee.capsTable.install(
            Capability(target: .endpoint(endpoint), badge: Badge(0), rights: [.send, .read, .write])
        )
        #expect(handle != nil)

        #expect(address(process, handle!, 0) == nil)
        #expect(address(process, 15, 0) == nil)
        #expect(address(process, 0, 0) == nil)
    }


    @Test("a window of whole pages is the one that may be mapped instead")
    func pageSizedWindowsAreTheMappableOnes() {
        // The rule `MapDeviceSyscall` enforces, stated here as the arithmetic it
        // rests on: the UART's window is exactly a page, a virtio slot is an
        // eighth of one, and there is no page size between them.
        let uart   = DeviceRegion(address: 0x0900_0000, size: 0x1000)
        let virtio = DeviceRegion(address: 0x0A00_0000, size: 0x200)
        let page   = UserSpaceLayout.pageSize

        #expect(uart.size >= page && uart.size % page == 0 && uart.address % page == 0)
        #expect(virtio.size < page)
    }
}
