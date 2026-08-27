//
//  Verbs.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.
//

/// Every verb the shell answers to, and what each one takes.
///
/// Here rather than beside the modules because the modules cannot be reached
/// from a host at all - they are built against the syscall stubs - and a table
/// nothing can hold to its own numbers is a table that drifts. What the modules
/// keep is the doing and the printing.
///
/// The names are the commands as typed, so a signature and its use are the same
/// word read twice.
public enum Verbs {

    // The shell talking about itself.
    public static let shellHelp = Arity.none("shell.help takes no arguments")
    public static let shellHalt = Arity.none("shell.halt takes no arguments")
    public static let shellExit = Arity.none("shell.exit takes no arguments")

    // The process table.
    public static let processList  = Arity.none("process.list takes no arguments")
    public static let processSpawn = Arity.exactly(
        1, "process.spawn takes one name, as in process.spawn(\"Top.elf\")"
    )

    // The disk, sector by sector.
    public static let diskInfo = Arity.none("disk.info takes no arguments")
    public static let diskRead = Arity.exactly(
        1, "disk.read takes one sector number, as in disk.read(0)"
    )

    // Names, folders and containers.
    public static let fsWhere   = Arity.none("fs.where takes no arguments")
    public static let fsFree    = Arity.none("fs.free takes no arguments")
    public static let fsUnmount = Arity.none("fs.unmount takes no arguments")
    public static let fsScrub   = Arity.none("fs.scrub takes no arguments")

    /// The one verb with a choice, and it is deliberate: nothing lists where the
    /// shell is standing, a path lists there instead.
    public static let fsList = Arity(
        0, 1, "fs.list takes nothing, or one path, as in fs.list docs"
    )

    public static let fsMove = Arity.exactly(
        1, "fs.move takes one path, as in fs.move reix::app::child/doc"
    )
    public static let fsInfo = Arity.exactly(
        1, "fs.info takes one path, as in fs.info a.txt"
    )
    public static let fsRead = Arity.exactly(
        1, "fs.read takes one path, as in fs.read a.txt"
    )
    public static let fsFolder = Arity.exactly(
        1, "fs.folder takes one name, as in fs.folder docs"
    )
    public static let fsRemove = Arity.exactly(
        1, "fs.remove takes one path, as in fs.remove a.txt"
    )
    public static let fsName = Arity.exactly(
        1, "fs.name takes one word, as in fs.name laboratorio"
    )
    public static let fsCompact = Arity.exactly(
        1, "fs.compact takes one path, as in fs.compact a.bin"
    )

    public static let fsWrite = Arity.exactly(
        2, "fs.write takes a path and some text, as in fs.write a.txt \"hello\""
    )
    public static let fsContainer = Arity.exactly(
        2, "fs.container takes a name and a size in blocks, as in fs.container app 64"
    )
    public static let fsRename = Arity.exactly(
        2, "fs.rename takes what to move and where to, as in fs.rename a.txt docs/b.txt"
    )
}
