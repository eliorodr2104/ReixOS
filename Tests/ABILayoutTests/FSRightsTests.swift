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


    @Test("looking is not touching")
    func readingChangesNothing() {
        let reader = FSRights.reader

        #expect(reader.contains(.lookup))
        #expect(reader.contains(.read))

        for right in [FSRights.write, .remove, .delegate, .quota, .admin, .unmount] {
            #expect(!reader.contains(right))
        }
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
