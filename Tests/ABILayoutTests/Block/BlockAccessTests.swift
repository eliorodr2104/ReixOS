//
//  BlockAccessTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.


import Testing
import ReixABI

/// Who may write a disk, and when anybody else may look at it.
///
/// This is the rule that makes the file system the only arbiter of the format
/// rather than merely the politest process on the machine, so it is checked
/// here, where it is three integers and no hardware, instead of by watching a
/// boot and hoping.
@Suite("Volume access")
struct BlockAccessTests {

    private static let disk    : UInt64 = BlockOperation.Badge.disk
    private static let looking : UInt64 = BlockOperation.Badge.readOnly
    private static let warden  : UInt64 = BlockOperation.Badge.warden

    private static let files   : UInt32 = 7                     // the mounter
    private static let shell   : UInt32 = 9                     // somebody else


    private func check(
        _ operation: BlockOperation,
          session  : UInt64,
          holder   : UInt32?,
          caller   : UInt32
    ) -> BlockStatus {
        BlockAccess.check(operation, session: session, holder: holder, caller: caller)
    }


    @Test("nobody writes a disk nobody has claimed")
    func unclaimedIsUnwritable() {
        #expect(check(.write, session: Self.disk, holder: nil, caller: Self.files)
                == .notMounted)
    }


    @Test("the holder writes and nobody else does")
    func onlyTheHolderWrites() {
        #expect(check(.write, session: Self.disk, holder: Self.files, caller: Self.files)
                == .ok)
        #expect(check(.write, session: Self.disk, holder: Self.files, caller: Self.shell)
                == .notMounted)
    }


    @Test("a read-only view cannot write, claimed or not")
    func lookingCannotWrite() {
        for holder in [nil, Self.files, Self.shell] as [UInt32?] {
            #expect(check(.write, session: Self.looking, holder: holder, caller: Self.shell)
                    == .readOnly)
        }
    }


    @Test("a read-only view cannot take the volume either")
    func lookingCannotMount() {
        #expect(check(.mount, session: Self.looking, holder: nil, caller: Self.shell)
                == .readOnly)
    }


    @Test("the volume goes to one process at a time")
    func mountIsExclusive() {
        #expect(check(.mount, session: Self.disk, holder: nil, caller: Self.files)
                == .ok)
        #expect(check(.mount, session: Self.disk, holder: Self.files, caller: Self.shell)
                == .volumeHeld)

        // Its own claim again, which is what a restarted mount looks like.
        #expect(check(.mount, session: Self.disk, holder: Self.files, caller: Self.files)
                == .ok)
    }


    @Test("only the holder gives the volume back")
    func onlyTheHolderReleases() {
        #expect(check(.unmount, session: Self.disk, holder: Self.files, caller: Self.shell)
                == .notMounted)
        #expect(check(.unmount, session: Self.disk, holder: Self.files, caller: Self.files)
                == .ok)
    }


    @Test("a read-only view reads a quiet disk and not a mounted one")
    func lookingReadsWhenQuiet() {
        #expect(check(.read, session: Self.looking, holder: nil, caller: Self.shell)
                == .ok)
        #expect(check(.read, session: Self.looking, holder: Self.files, caller: Self.shell)
                == .volumeHeld)
    }


    @Test("the disk itself is readable throughout, because it is the mounter")
    func theDiskReadsThroughout() {
        #expect(check(.read, session: Self.disk, holder: nil, caller: Self.files) == .ok)
        #expect(check(.read, session: Self.disk, holder: Self.files, caller: Self.files) == .ok)
    }


    @Test("asking what the device is, and where the bytes go, is never refused")
    func geometryAndAttachAlwaysPass() {
        for operation in [BlockOperation.attach, .geometry] {
            #expect(check(operation, session: Self.looking, holder: Self.files, caller: Self.shell)
                    == .ok)
        }
    }


    // MARK: - The warden

    @Test("a warden ends a claim it does not hold, which is the whole point")
    func wardenReclaims() {
        // Not the holder, and that is exactly the case: the holder is gone.
        #expect(check(.reclaim, session: Self.warden, holder: Self.files, caller: Self.shell)
                == .ok)
        #expect(check(.reclaim, session: Self.warden, holder: nil, caller: Self.shell)
                == .ok)
    }


    @Test("a warden may do nothing else at all")
    func wardenHasNoOtherPower() {
        for operation in [BlockOperation.attach, .geometry, .read, .write, .mount, .unmount] {
            #expect(check(operation, session: Self.warden, holder: nil, caller: Self.shell)
                    == .notAuthorised)
        }
    }


    @Test("nobody else may say a holder is gone")
    func onlyTheWardenReclaims() {
        for session in [Self.disk, Self.looking] {
            #expect(check(.reclaim, session: session, holder: Self.files, caller: Self.files)
                    == .notAuthorised)
        }
    }


    @Test("a badge nobody minted carries no authority whatsoever")
    func unknownBadgeCarriesNothing() {
        let invented: UInt64 = 0xFEED

        for operation in [BlockOperation.attach, .geometry, .read, .write,
                          .mount, .unmount, .reclaim] {
            #expect(check(operation, session: invented, holder: nil, caller: Self.shell)
                    == .notAuthorised)
        }
    }


    @Test("a read-only view cannot end a claim, which is what keeps a mount safe")
    func lookingCannotReclaim() {
        // The shell holds this badge. If it could reclaim, anybody at the
        // keyboard could pull the volume out from under a live file system and
        // every write after that would be refused mid-operation.
        #expect(check(.reclaim, session: Self.looking, holder: Self.files, caller: Self.shell)
                == .notAuthorised)
        #expect(check(.unmount, session: Self.looking, holder: Self.files, caller: Self.shell)
                == .notAuthorised)
    }
}
