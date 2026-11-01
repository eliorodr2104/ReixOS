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

    /// Bytes moved per read and per write into the task: one page.
    static let chunk = 4096

    /// Claims `file`, plans it, and hands the plan to `build`, letting go of the
    /// claim whatever `build` answers.
    ///
    /// `build` makes the task and copies the image into it, through `copy`
    /// below, from the same claimed file it is handed.
    public static func load<File: ProgramFile>(
        _ file: inout File,
        build : (ELFLoadPlan, inout File) -> ProcessServerStatus
    ) -> ProcessServerStatus {

        let claimed = file.claim()
        guard claimed == .ok else { return claimed }

        defer { file.release() }

        guard case .success(let plan) = ELFPlanner.plan(from: &file) else {
            return .malformedELF
        }

        return build(plan, &file)
    }


    /// Copies every byte of `plan` that comes from the file, a page at a time,
    /// handing each page to `write` at the address it belongs at.
    ///
    /// `false` at the first read or write that fails, with whatever was copied
    /// before it left where it landed: the task is discarded, not repaired.
    public static func copy<Source: ELFByteSource>(
        _ plan    : ELFLoadPlan,
        from file : inout Source,
        into write: (_ address: UInt64, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool
    ) -> Bool {

        withUnsafeTemporaryAllocation(byteCount: chunk, alignment: 16) { buffer in
            guard let page = buffer.baseAddress else { return false }

            for index in 0..<plan.copyCount {
                guard let copy = plan.copy(at: index) else { return false }

                var offset: UInt64 = 0
                while offset < copy.byteCount {
                    let wanted = Int(min(copy.byteCount - offset, UInt64(chunk)))

                    guard file.read(at: copy.fileOffset + offset, into: page, count: wanted),
                          write(copy.virtualAddress + offset, UnsafeRawPointer(page), wanted)
                    else { return false }

                    offset += UInt64(wanted)
                }
            }
            return true
        }
    }
}
