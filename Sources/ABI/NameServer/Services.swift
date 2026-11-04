//
//  Services.swift
//  ReixOS
//
//  Created by Eliomar on 02/08/2026.
//

/// The things a process may find by asking rather than by being given one.
///
/// Every name here is something it is safe for anybody to reach, which is why so
/// few of them are. A name is a lookup anybody may do, so a named thing is a
/// thing with no owner - and the disk, the file system and the terminal are all
/// things somebody is *handed*, by whoever decided they should have one. They
/// were once in this list and are not any more, and nothing looked them up while
/// they were.
///
/// What is left is the one service that really is for everybody: the way to ask
/// for a program to be run.
///
/// TODO: - and nothing publishes it at the moment. The Process Server is
/// disabled until it can read an image off the volume rather than name one the
/// build compiled in, so this is a name with nobody behind it. It stays because
/// it is what comes back, and the Name Server's table is sized from it.
public enum Services: UInt32 {
    case processServer = 0

    /// How many names there are, which is how wide the Name Server's table has
    /// to be. It lives here rather than there because the two have to move
    /// together and only one of them is obvious to whoever adds a case.
    public static let count = 1
}
