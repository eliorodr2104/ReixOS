//
//  UserBootPresentation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 13/09/2026.
//

/// What a userland program is allowed to say while the machine is still coming
/// up, under the same contract the kernel applies to itself.
///
/// Without it a boot reads as two halves: a kernel that learned to be quiet
/// followed by nine servers that did not. So the rule is the same one on both
/// sides of the `eret`. `diagnostic` prints one line per service, `verbose`
/// prints only the two macro phases init owns, `standard` prints neither and
/// arrives at the shell having said nothing.
///
/// Failure is not this type's business. A server that cannot come up, a request
/// it refuses, a device that stopped answering: those are plain `print`, in
/// every mode, and nothing here should ever be reached for to quieten one.
public enum UserBootPresentation {

    /// Whether a service may announce itself at all.
    ///
    /// For the lines built from several pieces, a number or a name in the
    /// middle of them, where wrapping each `print` separately would say the
    /// same thing four times.
    @inline(__always)
    public static var showsServices: Bool { BootMode.current == .diagnostic }


    /// A service saying it is up, as one whole line.
    @inline(__always)
    public static func ready(_ line: StaticString) {
        guard showsServices else { return }

        print(line)
    }


    /// One of the two macro phases init owns.
    ///
    /// Never called by a server: a verbose boot prints five lines for the whole
    /// machine, not one per process that happens to reach its main loop.
    @inline(__always)
    public static func milestone(_ milestone: BootMilestone) {
        guard BootMode.current == .verbose else { return }

        print("[ INIT  ] ", terminator: "")
        print(milestone.label)
    }
}
