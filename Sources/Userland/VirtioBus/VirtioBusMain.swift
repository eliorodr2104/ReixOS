//
//  VirtioBusMain.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix
import ReixABI

/// Device id of a virtio block device.
private let blockDevice: UInt64 = 2

@_cdecl("_start")
public func main() {

    let environment = Runtime.bootstrap()

    guard let bus = environment.virtioBus else {
        print("[ BUS   ] no virtio bus on this machine")
        stop(1)
    }

    var block: VirtioBus.Transport? = nil

    VirtioBus.walk(bus: bus) { transport in
        print("[ BUS   ] slot ", terminator: "")
        printDec(UInt64(transport.slot), terminator: "")
        print(" version ", terminator: "")
        printDec(transport.version, terminator: "")
        print("  ", terminator: "")
        print(VirtioBus.name(of: transport.deviceID))

        guard transport.deviceID == blockDevice, block == nil else { return false }

        block = transport
        return true
    }

    guard let block else {
        print("[ BUS   ] no block device")
        stop(0)
    }

    // The line comes from the slot, not from a number this process was told:
    // which line a slot raises is the machine's business and the kernel read it
    // from the machine's own description.
    let interrupt = busDeriveInterrupt(handle: bus, index: block.slot)

    guard interrupt != UInt32.max else {
        print("[ BUS   ] block device found but its line is taken")
        stop(1)
    }

    guard let disk = startDriver(
        environment: environment,
        window     : block.window,
        interrupt  : interrupt
    ) else {
        stop(1)
    }

    // Handed over. From here this process holds no window and no line: what it
    // has left is one capability on a server, exactly like any other client.
    _ = capDrop(block.window)
    _ = capDrop(interrupt)

    let sound = checkDisk(disk)

    // And then not even that. The disk goes to whoever started this process,
    // once, and this one keeps nothing: a bus walker that could still read
    // sectors afterwards would be a second owner of the volume.
    handOver(disk)
    _ = capDrop(disk)

    exit(code: sound ? 0 : 1)
}


/// Gives the disk to whoever started this process.
///
/// One capability, once, with `.derive` so the receiver can cut a read-only
/// view out of it, and `.grant` so it can pass the disk itself on to the one
/// process meant to hold it.
private func handOver(_ disk: UInt32) {

    guard let parent = parentEndpoint() else { return }

    _ = send(
        handle     : parent,
        message    : BootMessage.announce.message,
        grant      : disk,
        grantRights: [.send, .grant, .derive]
    )
}


/// Stops, having first told the parent there is no disk.
///
/// The parent is waiting on this message, so every way out of here has to send
/// it. A bus that found nothing and said nothing would stop the whole machine
/// rather than just itself.
private func stop(_ code: Int32) -> Never {

    if let parent = parentEndpoint() {
        _ = send(handle: parent, message: BootMessage.announce.message)
    }

    exit(code: code)
}


/// Starts the process that will drive the disk, handing it the window and the
/// line and keeping neither.
///
/// This is the whole shape of the thing: authority over a device is carved out
/// of the bus, given to exactly one process, and given away rather than shared.
///
/// What comes back is the driver's endpoint, handed up by the driver itself
/// rather than published under a name. That is the difference between a disk
/// with an owner and a disk anybody can find.
private func startDriver(
    environment: Environment,
    window     : UInt32,
    interrupt  : UInt32
) -> UInt32? {

    guard let console = environment.console else {
        print("[ BUS   ] cannot start the disk driver: nothing to give it")
        return nil
    }

    let result = withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 3
    ) { grants in

        grants[0] = CapGrant(source: console,   slot: BootCap.console.rawValue,   rights: [.send, .grant])
        // `.dma` only here, and only for this one window. A driver that has to
        // put a ring where a device can read it needs to turn an address into a
        // physical one; nothing else this process starts does, and nothing else
        // gets to.
        grants[1] = CapGrant(source: window,    slot: BootCap.device.rawValue,    rights: [.read, .write, .dma])
        grants[2] = CapGrant(source: interrupt, slot: BootCap.interrupt.rawValue, rights: [.grant])

        return spawnProcess(path: "BlockServer.elf", grants: grants.baseAddress!, count: 3)
    }

    guard result.hasEndpoint else {
        print("[ BUS   ] the disk driver would not start")
        return nil
    }

    guard let disk = receive(handle: result.handle).grantedCap else {
        print("[ BUS   ] the disk driver came up without an endpoint")
        return nil
    }

    return disk
}


/// Reads the disk through the server, with no capability over the hardware at
/// all, in the one moment when doing so is safe: after the driver is up and
/// before anybody has been given the disk to mount.
///
/// Reads only, and not out of caution about this instant. The sectors are about
/// to belong to a file system, and nothing in this process would notice if they
/// already did; the server would refuse a write anyway, because a write needs
/// the volume and this process never claims it. What the write path does is
/// proved one level up, where a file written and read back says more than a
/// sector ever did.
private func checkDisk(_ endpoint: UInt32) -> Bool {

    guard var disk = BlockClient(block: endpoint) else {
        print("[ BUS   ] the disk would not attach")
        return false
    }

    print("[ BUS   ] disk ready, ", terminator: "")
    printDec(disk.sectorCount, terminator: "")
    print(" sectors")

    let size = Int(disk.sectorSize)

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: size) { sector in

        let base = UnsafeMutableRawPointer(sector.baseAddress!)

        guard disk.read(sector: 0, into: base) == .ok else {
            print("[ BUS   ] sector 0 unreadable")
            return false
        }

        guard disk.read(sector: disk.sectorCount - 1, into: base) == .ok else {
            print("[ BUS   ] the second request never completed")
            return false
        }

        guard disk.read(sector: disk.sectorCount, into: base) == .outOfRange else {
            print("[ BUS   ] a sector past the end of the disk was read")
            return false
        }

        print("[ BUS   ] two sectors read, one past the end refused")

        return checkRun(&disk)
    }
}


/// Reads a whole page of sectors in one call and checks the far end of it
/// against a single-sector read of the same place.
///
/// A run that is short, or that starts where it was told and then repeats the
/// first sector, passes every check that only looks at the beginning. Comparing
/// the *last* sector of the run against the same sector read on its own is what
/// makes the middle of the transfer mean something.
private func checkRun(_ disk: inout BlockClient) -> Bool {

    let run  = disk.maximumRun
    let size = Int(run * disk.sectorSize)

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: size) { many in
        let base = UnsafeMutableRawPointer(many.baseAddress!)

        guard disk.read(run, from: 0, into: base) == .ok else {
            print("[ BUS   ] a run of sectors could not be read")
            return false
        }

        guard disk.read(run + 1, from: 0, into: base) == .tooLong else {
            print("[ BUS   ] a run too long for the window was accepted")
            return false
        }

        return withUnsafeTemporaryAllocation(
            of      : UInt8.self,
            capacity: Int(disk.sectorSize)
        ) { one in

            guard disk.read(
                sector: run - 1,
                into  : UnsafeMutableRawPointer(one.baseAddress!)
            ) == .ok else {
                print("[ BUS   ] the last sector of the run could not be re-read")
                return false
            }

            let tail = Int((run - 1) * disk.sectorSize)

            for index in 0..<Int(disk.sectorSize) where many[tail + index] != one[index] {
                print("[ BUS   ] the run and the single read disagree at byte ", terminator: "")
                printDec(UInt64(index))
                return false
            }

            guard refusedWhenAskedDirectly(disk, count: run + 1) else { return false }

            print("[ BUS   ] read ", terminator: "")
            printDec(run, terminator: "")
            print(" sectors in one request")
            return true
        }
    }
}


/// Asks the server for a run that will not fit in the attached window, going
/// round the client's own bounds to do it.
///
/// The client refuses this before it costs a round trip, which is why the
/// server's identical check would otherwise never run. It has to be there
/// anyway: the client's bounds protect a client that is willing to be
/// protected, and the server's protect the disk from one that is not.
private func refusedWhenAskedDirectly(_ disk: BlockClient, count: UInt64) -> Bool {

    guard case .success(let answer) = call(
        handle : disk.endpoint,
        message: BlockOperation.read.transfer(count: UInt32(count), sector: 0)
    ) else {
        print("[ BUS   ] the server did not answer a request bigger than the window")
        return false
    }

    guard BlockOperation.status(of: answer.message) == .tooLong else {
        print("[ BUS   ] the server took a request bigger than the window")
        return false
    }

    return true
}


