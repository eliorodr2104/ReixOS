//
//  BlockAccess.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/08/2026.
//

/// Who may do what to a volume.
///
/// One function, and the block server's only rule about authority. It lives
/// here rather than inside the server for the same reason `BlockRange` does:
/// the answer is arithmetic over three facts and nothing else, so it can be
/// asked on a host with no disk, no kernel and no processes.
///
/// The three facts are the badge on the capability the request arrived through,
/// who is holding the volume, and who is asking. None of them comes out of the
/// message, which is the point: a client cannot say which view of the disk it
/// holds any more than it can say who it is.
public enum BlockAccess {

    /// `.ok` when `caller` may do `operation`, or the refusal to send back.
    ///
    /// The badge comes first, because it says what kind of holder this is and
    /// the three kinds have almost nothing in common: one holds the disk, one
    /// holds a view of it, and one holds neither and may only say that the
    /// first has died. A badge that is none of the three holds nothing, which
    /// is the safe way round for a word this code did not mint.
    ///
    /// Read the write case first, because it is the one the whole thing exists
    /// for: a sector is written by the process holding the volume and by nobody
    /// else, and a disk nobody has claimed is a disk nobody may write. There is
    /// no state in which a raw write lands underneath a mounted file system,
    /// because there is no state in which two processes hold the volume.
    public static func check(
        _ operation: BlockOperation,
          session  : UInt64,
          holder   : UInt32?,
          caller   : UInt32
    ) -> BlockStatus {

        switch session {

            case BlockOperation.Badge.disk:
                switch operation {
                    // What the device is, where this client's bytes will pass,
                    // and its own sectors. The holder of the disk always reads.
                    //
                    // `collect` is here and not with the writes because it asks
                    // for an answer and not for a change: what it is allowed to
                    // hand back was decided when the `begin` it belongs to was
                    // allowed or refused.
                    case .attach, .geometry, .read, .collect:
                        return .ok

                    // A `begin` is a read or a write, and which one is in the
                    // message rather than in the operation, so it is held to the
                    // stricter of the two: only the holder may start one.
                    case .begin:
                        return holder == caller ? .ok : .notMounted

                    // A flush goes with the writes it is a barrier for, so it
                    // is the holder's to ask for and nobody else's.
                    case .write, .unmount, .flush:
                        return holder == caller ? .ok : .notMounted

                    case .mount:
                        if let holder, holder != caller { return .volumeHeld }
                        return .ok

                    // Its own death is not a thing a process reports.
                    case .reclaim:
                        return .notAuthorised
                }

            case BlockOperation.Badge.readOnly:
                switch operation {
                    case .attach, .geometry:
                        return .ok

                    // A view meant for looking looks at a quiet disk. Under a
                    // mount it would be reading blocks halfway through a
                    // change, and reading them out of somebody else's container
                    // while it is at it.
                    case .read:
                        return holder == nil ? .ok : .volumeHeld

                    // Collecting is answering a question already asked, and a
                    // view that may not start one has none to collect.
                    case .collect:
                        return .ok

                    case .write, .mount, .flush, .begin:
                        return .readOnly

                    case .unmount, .reclaim:
                        return .notAuthorised
                }

            case BlockOperation.Badge.warden:
                // One power, and it is not a byte of the disk. A warden holds
                // no window here either, so it has no reason to attach.
                return operation == .reclaim ? .ok : .notAuthorised

            default:
                return .notAuthorised
        }
    }
}
