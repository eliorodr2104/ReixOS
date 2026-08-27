//
//  ArityTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/08/2026.


import Testing
import ShellLanguage

/// How many arguments each verb takes, held to the number it says.
///
/// The shell used to check this verb by verb, wherever somebody had remembered
/// to. `disk.read` counted its argument; `disk.info` took whatever was typed and
/// ignored it, which reads as a command that accepts an argument and does
/// nothing with it. A verb that ignores what it was handed is a verb that will
/// one day be handed something that matters.
///
/// The signatures live in the language rather than beside the modules for one
/// reason: this suite can reach them, and the modules cannot be reached from a
/// host at all. What a module still owns is the printing.
@Suite("Verb arity")
struct ArityTests {

    /// The whole vocabulary, with what the plan says each verb takes.
    private static let table: [(name: String, arity: Arity, least: Int, most: Int)] = [
        ("shell.help"    , Verbs.shellHelp    , 0, 0),
        ("shell.halt"    , Verbs.shellHalt    , 0, 0),
        ("shell.exit"    , Verbs.shellExit    , 0, 0),

        ("process.list"  , Verbs.processList  , 0, 0),
        ("process.spawn" , Verbs.processSpawn , 1, 1),

        ("disk.info"     , Verbs.diskInfo     , 0, 0),
        ("disk.read"     , Verbs.diskRead     , 1, 1),

        ("fs.where"      , Verbs.fsWhere      , 0, 0),
        ("fs.free"       , Verbs.fsFree       , 0, 0),
        ("fs.unmount"    , Verbs.fsUnmount    , 0, 0),
        ("fs.scrub"      , Verbs.fsScrub      , 0, 0),

        // The one verb with a choice, and it is deliberate: `fs.list` with
        // nothing lists where the shell stands, and with a path lists there.
        ("fs.list"       , Verbs.fsList       , 0, 1),

        ("fs.move"       , Verbs.fsMove       , 1, 1),
        ("fs.info"       , Verbs.fsInfo       , 1, 1),
        ("fs.read"       , Verbs.fsRead       , 1, 1),
        ("fs.folder"     , Verbs.fsFolder     , 1, 1),
        ("fs.remove"     , Verbs.fsRemove     , 1, 1),
        ("fs.name"       , Verbs.fsName       , 1, 1),
        ("fs.compact"    , Verbs.fsCompact    , 1, 1),

        ("fs.write"      , Verbs.fsWrite      , 2, 2),
        ("fs.container"  , Verbs.fsContainer  , 2, 2),
        ("fs.rename"     , Verbs.fsRename     , 2, 2),
    ]


    @Test("every verb takes what the plan says it takes")
    func theTableIsTheTable() {
        for entry in Self.table {
            #expect(entry.arity.least == entry.least, "\(entry.name) least")
            #expect(entry.arity.most  == entry.most,  "\(entry.name) most")
        }

        // Twenty-two verbs, so a verb added without a signature or a signature
        // added without a verb shows up here rather than in a boot.
        #expect(Self.table.count == 22)
    }


    @Test("every verb refuses one argument too few and one too many")
    func missingAndExtra() {
        for entry in Self.table {
            let arity = entry.arity

            if arity.least > 0 {
                #expect(!arity.accepts(arity.least - 1), "\(entry.name) took too few")
            }

            #expect(!arity.accepts(arity.most + 1), "\(entry.name) took an extra")

            // Everything in between, which for most of these is one number.
            for count in arity.least...arity.most {
                #expect(arity.accepts(count), "\(entry.name) refused \(count)")
            }
        }
    }


    @Test("no verb accepts a count that is not a count")
    func nonsenseCounts() {
        for entry in Self.table {
            #expect(!entry.arity.accepts(-1), "\(entry.name) took minus one")
            #expect(!entry.arity.accepts(Int.min), "\(entry.name) took the least Int")

            // Four is the most a parsed command can carry, so anything above it
            // cannot arrive; refusing it anyway costs nothing and means the
            // check does not depend on the parser's own limit.
            #expect(!entry.arity.accepts(5), "\(entry.name) took five")
            #expect(!entry.arity.accepts(Int.max), "\(entry.name) took the greatest Int")
        }
    }


    @Test("every verb has a usage line that names the verb it is about")
    func usageNamesTheVerb() {
        for entry in Self.table {
            let usage = String(describing: entry.arity.usage)

            // The receiver and verb as typed, so the line printed on a refusal
            // is about the command that was refused. A shared "wrong number of
            // arguments" would not be.
            #expect(usage.contains(entry.name), "\(entry.name): \(usage)")
        }
    }
}
