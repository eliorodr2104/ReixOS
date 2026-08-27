//
//  FSRights.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// What the holder of a file system capability may do with what it names.
///
/// This was one bit, `readOnly`, and one bit cannot say the things worth saying.
/// A capability that could write could also hand pieces of itself to other
/// processes, move room between containers, put the disk back together, rename
/// the machine and unmount the volume. Being allowed to write a file made you
/// the administrator of the disk, and there was no way to write down anything in
/// between.
///
/// The rule that makes a set of rights worth having is that it can only ever
/// narrow. A capability is minted from another one and takes the intersection,
/// so authority runs downhill and there is no request that widens it. Capsicum
/// is the design being followed here, and it is the monotonicity that does the
/// work rather than the length of the list.
///
/// Nine operations are outside the matrix. `attach` and `status` are how a
/// client says hello and learns which container it is in, so a capability that
/// could not make them would be a capability nobody could use at all.
public struct FSRights: OptionSet {

    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }


    /// Find things and ask what they are: `open`, `list`, `up`, `path`, `info`.
    ///
    /// Separate from reading bytes because knowing a folder's contents and
    /// reading them are different things to be allowed.
    public static let lookup = FSRights(rawValue: 1 << 0)

    /// Read the bytes of a file.
    public static let read = FSRights(rawValue: 1 << 1)

    /// Make things and change what they say: `create`, `write`, `replace`, and
    /// the `lock`/`unlock` pair that exists to make a run of writes indivisible.
    ///
    /// `compact` rides here too: putting an object back into one run of blocks
    /// rewrites it, and anybody who may rewrite it could have got the same
    /// result the long way round.
    public static let write = FSRights(rawValue: 1 << 2)

    /// Take things away and move them: `remove`, `relocate`.
    ///
    /// Held apart from `write` because "may add and change, may not destroy" is
    /// a shape worth being able to hand out.
    public static let remove = FSRights(rawValue: 1 << 3)

    /// Hand a piece of what this names to somebody else: `bind`.
    ///
    /// The one that spreads authority rather than using it, which is why it is
    /// its own bit. A process that should read one folder and nothing else has
    /// no business being able to give that folder away.
    public static let delegate = FSRights(rawValue: 1 << 4)

    /// Move room from this container into one inside it: `grantRoom`.
    ///
    /// Quota administration. Not writing: it decides how much anybody below may
    /// ever write.
    public static let quota = FSRights(rawValue: 1 << 5)

    /// Speak for the whole volume: `nameMachine`, `scrub`.
    public static let admin = FSRights(rawValue: 1 << 6)

    /// Mark the disk clean and stop serving it: `unmount`.
    ///
    /// Alone, because it ends the file system for everybody holding any part of
    /// it. Whoever may do that is not "a writer", it is the process that owns
    /// the machine.
    public static let unmount = FSRights(rawValue: 1 << 7)


    /// How wide the set is. The badge has to make room for exactly this many
    /// bits, and it takes them from the generation, so the number is a cost and
    /// not a free choice.
    public static let width: UInt32 = 8

    /// Every right there is, which is what the machine's own container carries
    /// and what nothing else should.
    public static let everything = FSRights(rawValue: (1 << width) - 1)

    /// May look and not touch. What was once the only alternative to everything.
    public static let reader: FSRights = [.lookup, .read]

    /// May keep files in a container of its own, and nothing beyond it: no
    /// handing pieces away, no room to move, no volume to speak for.
    public static let occupant: FSRights = [.lookup, .read, .write, .remove]


    /// The right an operation needs, or none for the two that every holder may
    /// make.
    ///
    /// The whole matrix, in one place, so that what an operation costs is
    /// readable next to what it does rather than spread through a switch in the
    /// server. An operation added without a line here needs nothing, which is
    /// the wrong default - so the switch is exhaustive and has no `default`.
    public static func required(for operation: FileOperation) -> FSRights {
        switch operation {
            case .attach, .status:
                []

            case .open, .list, .up, .path, .info:
                .lookup

            case .read:
                .read

            case .create, .write, .replace, .lock, .unlock, .compact:
                .write

            // Two rights and not one. A container is room set aside, so making
            // one is a use of the room-moving authority as much as of the
            // writing one - and `grantRoom` below already costs `.quota` for
            // moving room that has already been set aside.
            case .createContainer:
                [.write, .quota]

            case .remove, .relocate:
                .remove

            case .bind:
                .delegate

            case .grantRoom:
                .quota

            case .nameMachine, .scrub:
                .admin

            case .unmount:
                .unmount
        }
    }
}
