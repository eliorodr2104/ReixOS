//
//  ProgramLoad.swift
//  ReixOS
//

import ReixABI

/// Loading a program out of a file that nobody may change while it is read.
///
/// The plan comes from the headers and the bytes from the segments, and those
/// are many reads apart. A writer landing between two of them used to leave a
/// task built from the plan of one version and the bytes of another: an image
/// that was never on the disk. So the file is claimed before its first header
/// byte is read and let go after its last segment byte is copied, on every way
/// out of the load.
///
/// A claim somebody else holds is refused as `.busy` at once and never waited
/// for. Claims are refusals in this file system and not waits, a claim lasts as
/// long as its holder wants it to, and a ProcessServer sleeping on one would
/// stall every other launch behind a writer it cannot hurry. A holder that died
/// costs nothing here: the file system sweeps dead holders before it says no.
/// So the caller is told, and whoever asked for the program decides when to ask
/// again.
public enum ProgramLoad {
    static let chunk = 4096

    /// Claims `file` and plans it. Thrown: the claim's refusal, or `.malformedELF`
    /// after letting go. Returned: a plan, with the claim held by the caller.
    public static func begin<File: ProgramFile>(
        _ file: inout File
    ) throws(ProcessServerStatus) -> ELFLoadPlan {
        let claimed = file.claim()
        guard claimed == .ok else { throw claimed }
        guard case .success(let plan) = ELFPlanner.plan(from: &file) else {
            file.release()
            throw .malformedELF
        }
        return plan
    }
}
