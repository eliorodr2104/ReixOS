//
//  StorageCheckMain.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Reix
import ReixABI

/// Exercises the whole storage stack from the outside, holding nothing.
///
/// It has no window on a device, no interrupt, no block capability and no
/// knowledge of the format. It knows a name, and everything it does travels
/// down through the file system, the disk server, the driver, the queue and the
/// interrupt, and back. When this process prints its last line, all of that
/// worked.
@_cdecl("_start")
public func main() {

    let environment = Runtime.bootstrap()

    // No lookup and no name. This process sees a disk because one was handed to
    // it, and it sees exactly as much of it as was handed over.
    guard let handed = environment.container else {
        print("[ CHECK ] no container was given to this process")
        exit(code: 1)
    }

    guard let files = FileSystemClient(fileSystem: handed) else {
        print("[ CHECK ] the container would not attach")
        exit(code: 1)
    }

    // The name and not the number. What a client holds for an object is a
    // handle now, not an object number, and printing one as though it were an
    // identity invites somebody to read meaning into it.
    print("[ CHECK ] inside container ", terminator: "")
    for index in 0..<files.rootNameLength { putchar(ch: files.rootName[index]) }
    print("")

    let before = files.status()
    guard before.status == .ok else {
        print("[ CHECK ] the file system will not say how it is")
        exit(code: 1)
    }

    print("[ CHECK ] room left here ", terminator: "")
    printDec(UInt64(before.freeBlocks), terminator: "")
    print(" blocks")

    guard confined(files) else { exit(code: 1) }

    guard staleHandle(files) else { exit(code: 1) }

    let withListing = SystemClock.now()
    guard roundTrip(files, listing: true) else { exit(code: 1) }
    took(withListing, "with listing")

    let between = files.status().freeBlocks

    // Twice, and it is the second count that means something. The first round
    // trip may leave the root folder one block bigger than it found it, because
    // a folder that grew to hold a name keeps the room afterwards. What must not
    // happen is losing a block on every round trip, and only two of them in a
    // row can tell those two apart.
    let withoutListing = SystemClock.now()
    guard roundTrip(files, listing: false) else { exit(code: 1) }
    took(withoutListing, "no listing  ")

    let after = files.status().freeBlocks

    guard after == between else {
        print("[ CHECK ] space leaks: ", terminator: "")
        printDec(UInt64(between), terminator: "")
        print(" then ", terminator: "")
        printDec(UInt64(after))
        exit(code: 1)
    }

    guard claimsHold(files) else { exit(code: 1) }
    guard let borrowed = readTheLoan(environment) else { exit(code: 1) }
    guard poured(matches: borrowed) else { exit(code: 1) }

    // A window of its own: the server keys one per identity, so the loan's
    // attach above replaced this container's and let go of what it held.
    guard let again = FileSystemClient(fileSystem: handed) else {
        print("[ CHECK ] the container would not attach a second time")
        exit(code: 1)
    }

    guard denseFiles(again) else { exit(code: 1) }

    guard secondAttachment(environment) else { exit(code: 1) }

    guard claimAbandoned(again) else { exit(code: 1) }

    print("[ CHECK ] storage stack whole, nothing leaked")
    exit(code: 0)
}


/// A file with a hole in it is a file this format does not have.
///
/// A write that starts past the end used to be filled in: the blocks of the gap
/// allocated and a page of zeros written into each, so a one-byte write eight
/// megabytes out was an eight-megabyte write. Now it is refused, with an answer of
/// its own, and refused before anything is charged or allocated.
private func denseFiles(_ files: FileSystemClient) -> Bool {

    let name  = "dense.bin" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)

    let made = files.create(bytes, length: name.utf8CodeUnitCount)
    guard made.status == .ok, let file = made.file else {
        print("[ CHECK ] the file for the dense check was not made")
        return false
    }

    let before = files.status().freeBlocks

    let word = "x" as StaticString

    // A megabyte out on a file of no length, which is the shape that used to
    // cost two hundred and fifty-six blocks and as many page writes.
    let refused = files.write(
        file.object, at: 1 << 20, from: UnsafeRawPointer(word.utf8Start), count: 1
    )

    guard refused.status == .pastTheEnd, refused.bytes == 0 else {
        print("[ CHECK ] a write past the end of a file was not refused")
        return false
    }

    guard files.status().freeBlocks == before else {
        print("[ CHECK ] a refused write past the end still cost blocks")
        return false
    }

    // At the end is the one that works, and then again at the new end.
    guard files.write(
        file.object, at: 0, from: UnsafeRawPointer(word.utf8Start), count: 1
    ).status == .ok,
          files.write(
        file.object, at: 1, from: UnsafeRawPointer(word.utf8Start), count: 1
    ).status == .ok
    else {
        print("[ CHECK ] a write at the end of a file was refused")
        return false
    }

    guard files.open(bytes, length: name.utf8CodeUnitCount).file?.size == 2 else {
        print("[ CHECK ] the dense file is not two bytes long")
        return false
    }

    guard files.remove(bytes, length: name.utf8CodeUnitCount) == .ok else {
        print("[ CHECK ] the dense file would not be removed")
        return false
    }

    print("[ CHECK ] a write past the end is refused and costs nothing")
    return true
}


/// Holds a window on the disk while the file system is holding the volume.
///
/// Two clients attached to the block server at the same time, which is the state
/// nothing else on this machine reaches: the bus hands the disk on and keeps
/// nothing, and the shell attaches only when somebody types at it. What it
/// proves is that a second window neither disturbs the first nor gains anything
/// from existing - the geometry comes back, a read does not, and every file
/// system operation after this one still works.
///
/// It also attaches twice, on purpose. Replacing a window is one store now and
/// the old one is surrendered after the new one is installed, so doing it while
/// another client's requests are going round is the case worth walking on a real
/// machine rather than only on a host.
private func secondAttachment(_ environment: Environment) -> Bool {

    // Nothing is looked up. A view of the disk is something a parent hands
    // down, and a machine with no disk hands down nothing.
    guard let endpoint = environment.block else {
        print("[ CHECK ] no view of the disk was given to this process")
        return false
    }

    guard let disk = BlockClient(block: endpoint) else {
        print("[ CHECK ] the view of the disk would not attach")
        return false
    }

    guard disk.sectorCount > 0, disk.sectorSize > 0 else {
        print("[ CHECK ] the disk answered no geometry to a second attachment")
        return false
    }

    // Refused for the right reason: `notAttached` would mean this window never
    // arrived, and reading that as success is a test passing for nothing.
    let room = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
    defer { room.deallocate() }

    let refused = disk.read(1, from: 0, into: room)

    guard refused == .volumeHeld else {
        print("[ CHECK ] a read from a second attachment answered ", terminator: "")
        printDec(UInt64(refused.rawValue))
        return false
    }

    // Again, while the first attachment's client is still working. The old
    // window is surrendered only after the new one is installed.
    guard let replaced = BlockClient(block: endpoint) else {
        print("[ CHECK ] the view of the disk would not attach a second time")
        return false
    }

    guard replaced.sectorCount == disk.sectorCount else {
        print("[ CHECK ] the replaced window answered a different disk")
        return false
    }

    print("[ CHECK ] a second window on the disk, held while the file system holds it")

    return forgedInterrupt(endpoint, replaced)
}


/// Sends the block server a message wearing its device's label.
///
/// The one thing a client should never be able to do. Acted on, it would have the
/// server read the transport's interrupt-status register, write the acknowledge
/// register and acknowledge the kernel's line - on demand, from here, and on a
/// shared line that would be somebody else's device.
///
/// It is a `send` and not a `call`, because nothing answers one: a notification
/// has no reply. What says it was refused is the server's own line and the disk
/// still working afterwards.
private func forgedInterrupt(
    _ endpoint: UInt32,
    _ disk    : BlockClient
) -> Bool {

    var words = InlineArray<4, UInt32>(repeating: 0)

    // Every line at once, which is what a forgery would ask for: acknowledge
    // whatever is pending, whoever it belongs to.
    words[0] = UInt32.max

    let sent = send(
        handle : endpoint,
        message: Message(
            tag  : MessageTag(
                packed: (UInt64(InterruptNotification.label) << 8) | 1
            ),
            words: words
        )
    )

    guard sent == .ok else {
        print("[ CHECK ] the forged interrupt could not be sent, so nothing was proved")
        return false
    }

    // A server that had acted on it would have acknowledged a line nothing
    // raised, which is how a real completion goes missing.
    let room = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
    defer { room.deallocate() }

    guard disk.read(1, from: 0, into: room) == .volumeHeld else {
        print("[ CHECK ] the disk stopped answering after a forged interrupt")
        return false
    }

    print("[ CHECK ] a forged interrupt reached neither the transport nor the line")
    return true
}


/// Takes a claim and dies holding it, on purpose.
///
/// The half of `claimsHold` one process cannot show. A claim is an application
/// lock, so a claim that outlives its holder is a file nobody can ever write
/// again - and nothing tells a server that a client has died. What proves it was
/// let go of is the process that outlives this one: init reaps this corpse and
/// then writes this same file. See `orphanedClaim` in Init.
///
/// Deliberately last, and deliberately not undone.
private func claimAbandoned(_ files: FileSystemClient) -> Bool {

    let name  = "orphan.bin" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    // The disk outlives a boot, so the file is here from the last run. What must
    // be fresh is the claim, and a claim lives in the server's memory only.
    var file = files.open(bytes, length: count).file?.object

    if file == nil {
        let made = files.create(bytes, length: count, kind: .file)
        file = made.file?.object

        guard file != nil else {
            print("[ CHECK ] the file to abandon a claim on was not made, status ", terminator: "")
            printDec(UInt64(made.status.rawValue))
            return false
        }
    }

    guard let file else { return false }

    guard files.lock(file) == .ok else {
        print("[ CHECK ] the claim to abandon was refused")
        return false
    }

    print("[ CHECK ] a claim is taken and this process dies holding it")
    return true
}


/// Claims a file, checks the claim is answered, and lets it go.
///
/// One process cannot show that a claim keeps a second one out - it would have
/// to be two processes. What it can show is that the claim is taken, that
/// taking it twice from the same holder is allowed, and that it survives being
/// let go. The part a second process would prove is the part the server's own
/// table decides, and it is three lines.
private func claimsHold(_ files: FileSystemClient) -> Bool {

    let name  = "claimed.bin" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    _ = files.remove(bytes, length: count)

    let made = files.create(bytes, length: count, kind: .file)
    guard made.status == .ok, let file = made.file else {
        print("[ CHECK ] the file to claim was not made")
        return false
    }

    guard files.lock(file.object) == .ok else {
        print("[ CHECK ] the claim was refused")
        return false
    }

    // The holder claiming it again is the holder, not somebody else.
    guard files.lock(file.object) == .ok else {
        print("[ CHECK ] a holder was refused its own claim")
        return false
    }

    let payload = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { payload.deallocate() }
    payload.initializeMemory(as: UInt8.self, repeating: 0x77, count: 64)

    guard files.write(file.object, at: 0, from: UnsafeRawPointer(payload), count: 64).status == .ok
    else {
        print("[ CHECK ] the holder could not write what it had claimed")
        return false
    }

    files.unlock(file.object)

    guard files.remove(bytes, length: count) == .ok else {
        print("[ CHECK ] a released file would not be removed")
        return false
    }

    print("[ CHECK ] a claim is taken, honoured and let go")
    return true
}


/// How big the lent file is. Both sides know it because both were told; nothing
/// here derives it from anything it should not be able to see.
private let giftSize = 2000


/// Reads the one file this process was lent out of somebody else's container,
/// and checks that lending it lent nothing else.
///
/// The capability names a file, so the boundary it draws contains exactly one
/// thing. Everything a container capability would allow, this one refuses:
/// listing what is beside it, making anything next to it, and writing the file
/// itself, because it was handed over read-only.
private func readTheLoan(_ environment: Environment) -> UnsafeMutableRawPointer? {

    guard let handle = environment.shared else {
        print("[ CHECK ] nothing was lent to this process")
        return nil
    }

    guard let loan = FileSystemClient(fileSystem: handle) else {
        print("[ CHECK ] the loan would not attach")
        return nil
    }

    let bytes = UnsafeMutableRawPointer.allocate(byteCount: giftSize, alignment: 8)

    let read = loan.read(loan.root, at: 0, into: bytes, count: UInt64(giftSize))

    guard read.status == .ok, read.bytes == UInt64(giftSize) else {
        print("[ CHECK ] the lent file did not read")
        bytes.deallocate()
        return nil
    }

    print("[ CHECK ] read ", terminator: "")
    printDec(read.bytes, terminator: "")
    print(" bytes of a file lent from another container")

    // Read-only means read-only, and it says so rather than pretending the
    // file is not there: this process was handed it on purpose.
    let name = "sneak" as StaticString

    guard loan.write(loan.root, at: 0, from: UnsafeRawPointer(bytes), count: 8).status == .readOnly else {
        print("[ CHECK ] a read-only loan was written to")
        bytes.deallocate()
        return nil
    }

    // And a file is a boundary containing one thing, so there is nothing beside
    // it to see, make or take.
    guard loan.listBatch(from: 0, into: bytes, capacity: 1).status != .ok,
          loan.create(
              UnsafeRawPointer(name.utf8Start),
              length: name.utf8CodeUnitCount,
              kind  : .file
          ).status != .ok
    else {
        print("[ CHECK ] the loan reached past the file it named")
        bytes.deallocate()
        return nil
    }

    print("[ CHECK ] the loan is read-only and reaches nothing else")

    // Read again: the failed attempts above used this buffer for their own
    // purposes, and what is compared next has to be what came off the disk.
    guard loan.read(loan.root, at: 0, into: bytes, count: UInt64(giftSize)).bytes == UInt64(giftSize)
    else {
        bytes.deallocate()
        return nil
    }

    return bytes
}


/// Takes the same file down the pipe and compares it with the lent copy.
///
/// Two roads to the same bytes, and that is the point of running both. Down
/// this one nothing arrives but the bytes: no capability, no number, no name,
/// no way to ask for a second thing. If the two agree, the untrusted road
/// carried the file faithfully while telling the receiver nothing.
private func poured(matches lent: UnsafeMutableRawPointer) -> Bool {

    defer { lent.deallocate() }

    guard let endpoint = parentEndpoint() else {
        print("[ CHECK ] no pipe to receive on")
        return false
    }

    var consumer = PipeConsumer(on: endpoint)
    defer { consumer.close() }

    let arrived = UnsafeMutableRawPointer.allocate(byteCount: giftSize, alignment: 8)
    defer { arrived.deallocate() }

    var filled = 0

    while true {
        let taken = consumer.take(
            into    : arrived.advanced(by: filled),
            capacity: giftSize - filled
        )
        guard taken.status == .ok else {
            print("[ CHECK ] the pipe did not finish cleanly")
            return false
        }
        filled += taken.count
        if taken.ended { break }
    }

    guard filled == giftSize else {
        print("[ CHECK ] the pipe delivered ", terminator: "")
        printDec(UInt64(filled), terminator: "")
        print(" bytes instead of the whole file")
        return false
    }

    let one = lent.assumingMemoryBound(to: UInt8.self)
    let two = arrived.assumingMemoryBound(to: UInt8.self)

    for index in 0..<giftSize where one[index] != two[index] {
        print("[ CHECK ] the two roads disagree at byte ", terminator: "")
        printDec(UInt64(index))
        return false
    }

    print("[ CHECK ] the same ", terminator: "")
    printDec(UInt64(giftSize), terminator: "")
    print(" bytes arrived down the pipe, and match")

    return true
}


/// Keeps a handle for a file that is then removed, and uses it afterwards.
///
/// The sequence, and it needs no crash and no race: open something and keep what
/// `open` answered, remove it, make another thing which is given the slot the
/// first one had, and use the old handle. It used to reach the new file, because
/// the handle was a slot number and a slot outlives the things that pass
/// through it.
///
/// Both files are inside this one container, so containment cannot tell them
/// apart - it says yes to both. Only the handle can, which is why it carries the
/// count of the slot as well as the number of it.
private func staleHandle(_ files: FileSystemClient) -> Bool {

    let first  = "one.txt" as StaticString
    let second = "two.txt" as StaticString

    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
    defer { scratch.deallocate() }

    // Cleared first, because the scenario rows share one disk image and a row
    // that stopped in the middle of this leaves its files behind. A check that
    // reports `exists` on the next boot is reporting the previous failure, which
    // is the one thing a check must not do.
    _ = files.remove(UnsafeRawPointer(first.utf8Start),  length: first.utf8CodeUnitCount)
    _ = files.remove(UnsafeRawPointer(second.utf8Start), length: second.utf8CodeUnitCount)

    let made = files.create(UnsafeRawPointer(first.utf8Start), length: first.utf8CodeUnitCount)

    guard made.status == .ok, let held = made.file?.object else {
        print("[ CHECK ] the file to hold a handle for was not made")
        return false
    }

    // Written to, so that a read which wrongly succeeds later comes back with
    // somebody else's bytes rather than with nothing.
    let mark = "one" as StaticString
    guard files.write(
        held, at: 0, from: UnsafeRawPointer(mark.utf8Start), count: 3
    ).status == .ok else {
        print("[ CHECK ] the file to hold a handle for would not take bytes")
        return false
    }

    guard files.remove(
        UnsafeRawPointer(first.utf8Start), length: first.utf8CodeUnitCount
    ) == .ok else {
        print("[ CHECK ] the held file would not be removed")
        return false
    }

    // Step one: the handle is dead already, before anybody is given the slot.
    guard files.read(held, at: 0, into: scratch, count: 3).status != .ok else {
        print("[ CHECK ] a handle for a removed file still read it")
        return false
    }

    // Step two: the slot goes to something else. Which it does - the file system
    // remembers where the last free slot was - and that is the whole hazard.
    let next = files.create(UnsafeRawPointer(second.utf8Start), length: second.utf8CodeUnitCount)

    guard next.status == .ok, let fresh = next.file?.object else {
        print("[ CHECK ] the file to take the slot was not made")
        return false
    }

    let other = "two" as StaticString
    guard files.write(
        fresh, at: 0, from: UnsafeRawPointer(other.utf8Start), count: 3
    ).status == .ok else {
        print("[ CHECK ] the file that took the slot would not take bytes")
        return false
    }

    // Step three, which no longer follows. If the old handle reads anything it
    // is the new file, in this same container, under a name its holder was
    // never told.
    guard files.read(held, at: 0, into: scratch, count: 3).status != .ok else {
        print("[ CHECK ] a stale handle reached the file that took its slot")
        return false
    }

    // And the new file is genuinely there under its own handle, so none of the
    // above passed by there being nothing to find.
    let back = files.read(fresh, at: 0, into: scratch, count: 3)
    let got  = scratch.assumingMemoryBound(to: UInt8.self)

    guard back.status == .ok, back.bytes == 3,
          got[0] == other.utf8Start[0], got[2] == other.utf8Start[2]
    else {
        print("[ CHECK ] the file that took the slot cannot be read by its own handle")
        return false
    }

    guard files.remove(
        UnsafeRawPointer(second.utf8Start), length: second.utf8CodeUnitCount
    ) == .ok else {
        print("[ CHECK ] the file that took the slot would not be removed")
        return false
    }

    print("[ CHECK ] a handle for a removed file reaches nothing, not even its slot")
    return true
}


/// Tries to reach outside the container, the only ways there are.
///
/// There is no path to walk out of and no name to guess: what a client sends is
/// an object *number*, and the numbers are one space across the whole disk. So
/// the attack is simply to name somebody else's number, starting with zero,
/// which is the machine's own container and the most valuable thing there is.
///
/// Every one of these has to come back "no such name" and not "not yours".
/// Telling a caller that something exists but is not theirs is telling them
/// something.
private func confined(_ files: FileSystemClient) -> Bool {

    let name  = "escape" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    // The handle for the machine's own container, forged rather than given.
    //
    // It can be worked out because the machine's root is object zero and its
    // generation is zero and stays zero: the root is the one object `remove`
    // refuses, so nothing ever bumps its count. An object handle is the object
    // plus one in the low bits, so the machine is handle one, and that makes it
    // the most valuable guess on the disk and the one worth making by hand.
    let machine = UInt32(1)

    guard files.root != machine else {
        print("[ CHECK ] this process was given the whole machine")
        return false
    }

    // The machine's own container, named directly with a handle that is
    // perfectly well formed. This is the whole attack in one line: nothing about
    // the handle is wrong, it simply names something this process was not given.
    guard files.listBatch(
        machine, from: 0,
        into: UnsafeMutableRawPointer(mutating: bytes), capacity: 1
    ).status != .ok else {
        print("[ CHECK ] the machine's container listed itself to a container inside it")
        return false
    }

    guard files.create(bytes, length: count, kind: .file, in: machine).status == .notFound else {
        print("[ CHECK ] a file was created outside this container")
        return false
    }

    guard files.remove(bytes, length: count, from: machine) == .notFound else {
        print("[ CHECK ] a name outside this container answered a removal")
        return false
    }

    // A handle of zero, which is the one word that is not a handle at all.
    guard files.read(0, at: 0, into: UnsafeMutableRawPointer(mutating: bytes), count: 0).status
            != .ok else {
        print("[ CHECK ] a handle of zero answered from outside this container")
        return false
    }

    let scratch = UnsafeMutableRawPointer.allocate(byteCount: 512, alignment: 8)
    defer { scratch.deallocate() }

    // And sixty-three neighbours of this process's own handle, in case one of
    // them is somebody's.
    //
    // Built by flipping low bits of the handle it really holds, so the *count*
    // part is left exactly as it is: these are not wild numbers, they are
    // well-formed handles for other objects at a generation that is known to
    // exist. That is the guess with a chance, and every one of them has to come
    // back "no such name" rather than "not yours" - telling a caller that
    // something exists but is not theirs is telling them something.
    for twist in UInt32(1)..<UInt32(64) {
        let forged = files.root ^ twist

        let read = files.read(forged, at: 0, into: scratch, count: 16)

        guard read.status == .notFound else {
            print("[ CHECK ] a forged handle answered from outside this container")
            return false
        }
    }

    // Asking for a capability to the machine is the other way out, and it is
    // the same answer.
    guard files.bind(machine) == nil else {
        print("[ CHECK ] this process was handed the machine's container")
        return false
    }

    guard mayNotAdminister(files) else { return false }

    print("[ CHECK ] nothing outside this container can be reached")
    return true
}


/// The other kind of way out: not reaching somewhere else, but doing something
/// to the whole disk from where you are.
///
/// This process may keep files and hand a piece of its container to a child. It
/// may not move room between containers, speak for the volume, or unmount the
/// disk - and none of those are about reach. Writing a file used to carry all of
/// them, because the capability had one bit and that bit said "may touch".
///
/// Each of these is refused because the capability does not carry the right, and
/// the answer says so rather than pretending the thing is not there: this
/// process was handed its container deliberately.
private func mayNotAdminister(_ files: FileSystemClient) -> Bool {

    guard files.unmount() == .readOnly else {
        print("[ CHECK ] this process could unmount the volume")
        return false
    }

    guard files.scrub().status == .readOnly else {
        print("[ CHECK ] this process could scrub the whole disk")
        return false
    }

    let name = "stolen" as StaticString

    guard files.nameMachine(
        UnsafeRawPointer(name.utf8Start),
        length: name.utf8CodeUnitCount
    ) == .readOnly else {
        print("[ CHECK ] this process could rename the machine")
        return false
    }

    guard files.grantRoom(1, to: files.root) == .readOnly else {
        print("[ CHECK ] this process could move room between containers")
        return false
    }

    // A container is room set aside, so making one costs the same authority as
    // moving room. It used to cost what writing a file costs, because it
    // travelled as a word in a `create` payload: a tenant that could keep files
    // could carve a container out of the room it had been lent.
    let inner = "stolen-room" as StaticString

    guard files.createContainer(
        UnsafeRawPointer(inner.utf8Start),
        length: inner.utf8CodeUnitCount,
        room  : 1
    ).status == .readOnly else {
        print("[ CHECK ] this process could carve a container out of its own room")
        return false
    }

    // And the disk is still being served, which is the point of checking
    // `unmount` first: a refusal that had gone through would have taken the
    // file system away from everybody.
    guard files.status().status == .ok else {
        print("[ CHECK ] the volume did not survive being asked to unmount")
        return false
    }

    print("[ CHECK ] it keeps files and administers nothing")
    return true
}


/// Makes a file, fills it, reads it back, finds it by name, and takes it away.
private func roundTrip(
    _ files  : FileSystemClient,
      listing: Bool
) -> Bool {

    let name  = "check.bin" as StaticString
    let bytes = UnsafeRawPointer(name.utf8Start)
    let count = name.utf8CodeUnitCount

    // Left over from a previous boot, since the disk outlives it.
    _ = files.remove(bytes, length: count)

    let made = files.create(bytes, length: count, kind: .file)
    guard made.status == .ok, let file = made.file else {
        print("[ CHECK ] the file was not created")
        return false
    }

    // Wider than a block on purpose. A read this long is where the file system
    // asks the disk for several blocks before waiting for any of them, which is
    // the whole of what the queue underneath it is for - and a check that stayed
    // under one block would have left that path never run on a real machine.
    let size = 14000
    let out  = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    let back = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { out.deallocate(); back.deallocate() }

    // Mixed with the high byte of the index, so a transfer that repeats a block
    // fails the comparison instead of matching itself.
    let source = out.assumingMemoryBound(to: UInt8.self)
    for index in 0..<size {
        source[index] = UInt8((index * 7 + 13 + (index >> 8) * 31) & 0xFF)
    }

    let written = files.write(file.object, at: 0, from: UnsafeRawPointer(out), count: UInt64(size))
    guard written.status == .ok, written.bytes == UInt64(size) else {
        print("[ CHECK ] the write did not finish")
        return false
    }

    let read = files.read(file.object, at: 0, into: back, count: UInt64(size))
    guard read.status == .ok, read.bytes == UInt64(size) else {
        print("[ CHECK ] the file did not read back")
        return false
    }

    let got = back.assumingMemoryBound(to: UInt8.self)
    for index in 0..<size where got[index] != source[index] {
        print("[ CHECK ] the file came back different at byte ", terminator: "")
        printDec(UInt64(index))
        return false
    }

    print("[ CHECK ] wrote and read back ", terminator: "")
    printDec(UInt64(size), terminator: "")
    print(" bytes across ", terminator: "")
    printDec(UInt64((size + 4095) / 4096), terminator: "")
    print(" blocks")

    let opened = files.open(bytes, length: count)
    guard opened.status == .ok, opened.file?.size == UInt64(size) else {
        print("[ CHECK ] the file was not found by name, or has the wrong size")
        return false
    }

    if listing, !listed(files, is: name) { return false }

    guard files.remove(bytes, length: count) == .ok else {
        print("[ CHECK ] the file would not be removed")
        return false
    }

    guard files.open(bytes, length: count).status == .notFound else {
        print("[ CHECK ] a removed file is still there")
        return false
    }

    return true
}


/// How long something took, in microseconds, from this machine's own clock.
///
/// The only measurement this program can make. There is no clock in the hardware
/// here, so the reading is a number at all only because init set one from the
/// build stamp; the counter behind it moves forward regardless, which is what
/// makes a difference between two readings mean something even when the date
/// does not. An unset clock prints nothing rather than a duration of nowhere.
private func took(
    _ started: Time,
    _ what   : StaticString
) {

    let now = SystemClock.now()
    guard started.isKnown, now.isKnown else { return }

    print("[ CHECK ] round trip ", terminator: "")
    print(what, terminator: " ")
    printDec(now.since(started) / 1000, terminator: "")
    print(" us")
}


/// Whether the root folder lists the name, and prints everything it does list.
private func listed(
    _ files    : FileSystemClient,
      is wanted: StaticString
) -> Bool {

    var found = false

    // One batch of sixteen, which is one round trip for a folder this size where
    // it used to be one per name.
    withUnsafeTemporaryAllocation(
        of: UInt8.self, capacity: 16 * FSListEntry.width
    ) { room in
        let base = UnsafeMutableRawPointer(room.baseAddress!)

        var cursor = UInt32(0)

        func look(_ count: Int) {
            for index in 0..<count {
                let entry = FSListEntry(
                    reading: base.advanced(by: index * FSListEntry.width)
                )

                print("[ CHECK ] root holds ", terminator: "")
                for at in 0..<Int(entry.length) { putchar(ch: entry.name[at]) }
                print("")

                if Int(entry.length) == wanted.utf8CodeUnitCount {
                    var same = true
                    for at in 0..<Int(entry.length)
                    where entry.name[at] != wanted.utf8Start[at] { same = false }

                    if same { found = true }
                }
            }
        }

        // Whatever a batch found is looked at even when the batch also failed.
        // This loop used to judge the status first and break, which threw away
        // the names it had just been handed and reported nothing about why.
        walk: while true {
            let batch = files.listBatch(from: cursor, into: base, capacity: 16)

            switch batch.step {
                case .more(let count):
                    look(count)
                    cursor = batch.next

                case .end(let count):
                    look(count)
                    break walk

                case .stopped(let count, let why):
                    look(count)
                    print("[ CHECK ] the root listing stopped, status ", terminator: "")
                    printDec(UInt64(why.rawValue))
                    break walk
            }
        }
    }

    if !found { print("[ CHECK ] the file is not in the listing") }

    return found
}
