//
//  FSRightsTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

import Testing
import ReixABI

/// The rights matrix, checked as a table rather than trusted as a switch.
///
/// `FSRights.required(for:)` is the only place an operation's price is written
/// down, and the server reads it on every request, so a line put in the wrong
/// place here is a hole everywhere. The switch itself has no `default`, which is
/// what makes a newly added operation a compile error instead of an operation
/// that needs nothing.
@Suite("File system rights")
struct FSRightsTests {

    /// Every operation there is, walked by raw value so that one added without a
    /// line below shows up here too.
    private static var operations: [FileOperation] {
        var found: [FileOperation] = []
        var raw = UInt32(0)

        while let operation = FileOperation(rawValue: raw) {
            found.append(operation)
            raw += 1
        }

        return found
    }


    @Test("the two operations every holder may make are the only ones that are free")
    func onlyHelloIsFree() {
        for operation in Self.operations {
            let needed = FSRights.required(for: operation)

            switch operation {
                case .attach, .status:
                    #expect(needed.isEmpty)

                default:
                    // The dangerous direction. An operation that needs nothing
                    // is an operation any capability may make, including one
                    // handed out to be read-only.
                    #expect(!needed.isEmpty, "\(operation) requires no right at all")
            }
        }
    }


    @Test("every operation asks for exactly the right it is grouped under")
    func theMatrix() {
        let expected: [(FileOperation, FSRights)] = [
            (.attach,      []),
            (.status,      []),
            (.open,        .lookup),
            (.list,        .lookup),
            (.up,          .lookup),
            (.path,        .lookup),
            (.info,        .lookup),
            (.read,        .read),
            (.create,      .write),
            (.write,       .write),
            (.replace,     .write),
            (.lock,        .write),
            (.unlock,      .write),
            (.compact,     .write),
            (.remove,      .remove),
            (.relocate,    .remove),
            (.bind,        .delegate),
            (.grantRoom,   .quota),

            // Two rights, and the only entry here that needs both: a container
            // is room set aside, so making one is a use of the room-moving
            // authority as much as of the writing one.
            (.createContainer, [.write, .quota]),

            (.nameMachine, .admin),
            (.scrub,       .admin),
            (.unmount,     .unmount)
        ]

        for (operation, right) in expected {
            #expect(FSRights.required(for: operation) == right, "\(operation)")
        }

        // Nothing left out: the table above has to name every operation the
        // enum has, or an operation could drift to a cheaper right unwatched.
        #expect(expected.count == Self.operations.count)
    }


    /// What the report this closes was about. Writing a file used to carry
    /// handing pieces of it away, moving room between containers, speaking for
    /// the volume and unmounting it.
    @Test("keeping files is not administering the volume")
    func writingIsNotAdministering() {
        let tenant = FSRights.occupant

        #expect(tenant.contains(.write))
        #expect(tenant.contains(.remove))

        #expect(!tenant.contains(.delegate))
        #expect(!tenant.contains(.quota))
        #expect(!tenant.contains(.admin))
        #expect(!tenant.contains(.unmount))
    }


    /// Making a container is not the same act as making a file, and it used to
    /// travel as a word in the same message.
    ///
    /// `create` costs `.write`, which every tenant has. So the only thing between
    /// a tenant and a container of its own - carved out of the room it had been
    /// lent, with a quota it chose - was the `kind` field of a payload it wrote
    /// itself.
    @Test("an occupant cannot make a container, and the room-holder can")
    func containersCostQuota() {
        let needed = FSRights.required(for: .createContainer)

        #expect(needed.contains(.write))
        #expect(needed.contains(.quota))

        // A tenant holds everything `create` costs and not everything this does.
        #expect(FSRights.occupant.contains(FSRights.required(for: .create)))
        #expect(!FSRights.occupant.contains(needed))

        // A reader holds neither.
        #expect(!FSRights.reader.contains(needed))

        // And whoever was handed the room may hand a piece of it on.
        #expect(FSRights.everything.contains(needed))
    }


    @Test("which door a request came through decides what it may make")
    func theKindDoesNotChooseTheDoor() {
        // The kind in a payload is the client's word about what it wants. Which
        // operation it arrived as is not, because that is what the rights were
        // checked against - so a `.container` sent through `.create` is refused
        // rather than made at the price of a file.
        #expect(FileOperation.create.makes(.file))
        #expect(FileOperation.create.makes(.folder))
        #expect(!FileOperation.create.makes(.container))
        #expect(!FileOperation.create.makes(.free))

        #expect(FileOperation.createContainer.makes(.container))
        #expect(!FileOperation.createContainer.makes(.file))
        #expect(!FileOperation.createContainer.makes(.folder))
        #expect(!FileOperation.createContainer.makes(.free))

        // Nothing else makes anything at all, whatever kind it names.
        for operation in Self.operations
        where operation != .create && operation != .createContainer {
            for kind in [FSKind.free, .file, .folder, .container] {
                #expect(!operation.makes(kind), "\(operation) makes \(kind)")
            }
        }
    }


    @Test("looking is not touching")
    func readingChangesNothing() {
        let reader = FSRights.reader

        #expect(reader.contains(.lookup))
        #expect(reader.contains(.read))

        for right in [FSRights.write, .remove, .delegate, .quota, .admin, .unmount] {
            #expect(!reader.contains(right))
        }
    }


    /// A capability may deliberately root a client at one file (or folder),
    /// not only at a container.  `FileSystemClient` uses the full `status`
    /// reply as the attach acknowledgement, so this zero-room status must not
    /// be confused with the short successful status used for ordinary calls.
    @Test("a direct file root has a full zero-room attach acknowledgement")
    func directFileRootCanAcknowledgeAttach() {
        let fileRoot: UInt32 = 37
        let acknowledgement = FileOperation.standing(
            root: fileRoot, free: 0, used: 0, dirty: false
        )

        #expect(FileOperation.isAttachAcknowledgement(acknowledgement))
        #expect(acknowledgement.words[3] == fileRoot)
        #expect(acknowledgement.words[1] == 0)

        // A short `.ok` cannot name the root or prove the attach finished.
        #expect(!FileOperation.isAttachAcknowledgement(FileOperation.answer(.ok)))
        #expect(!FileOperation.isAttachAcknowledgement(FileOperation.answer(.wrongKind)))
    }


    @Test("everything is every right, and no more of the word than that")
    func everythingIsWhatItSays() {
        let all = FSRights.everything

        let named: [FSRights] = [
            .lookup, .read, .write, .remove, .delegate, .quota, .admin, .unmount
        ]

        for right in named { #expect(all.contains(right)) }

        // Exactly the named ones. A spare bit set in `everything` would be a
        // right nothing checks, quietly granted by every capability cut from the
        // machine's own container.
        #expect(all.rawValue == named.reduce(into: FSRights()) { $0.insert($1) }.rawValue)
        #expect(all.rawValue == (1 << FSRights.width) - 1)
    }


    /// Monotonicity, which is the property the whole design rests on: what comes
    /// out of a `bind` is what was asked for cut down to what the asker holds,
    /// so authority runs downhill and no request widens it.
    @Test("narrowing twice is never wider than narrowing once")
    func narrowingOnlyNarrows() {
        let steps: [FSRights] = [
            .everything, .occupant, .reader, [.lookup], [.unmount, .admin], []
        ]

        for held in steps {
            for asked in steps {
                let given = asked.intersection(held)

                #expect(held.contains(given))
                #expect(asked.contains(given))

                // And a second hop from there cannot recover what the first
                // dropped, whatever it asks for.
                #expect(held.contains(FSRights.everything.intersection(given)))
            }
        }
    }
}
