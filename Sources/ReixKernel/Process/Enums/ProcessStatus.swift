//
//  ProcessStatus.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/04/2026.
//

public enum ProcessStatus {
    case new
    case ready
    case running
    case waiting
    case blockedOnSend(UnsafeMutablePointer<Endpoint>?)
    case blockedOnReceive(UnsafeMutablePointer<Endpoint>?)
    /// Waiting for `Process` to answer a call, and carrying which process that
    /// is.
    ///
    /// The payload is free: the two cases above already make this enum one
    /// pointer plus a tag, and this case used to leave that pointer empty. It
    /// replaced a stored `replyPartner` field, which cost eight bytes and could
    /// disagree with the status - a process not blocked on a reply but still
    /// naming a server it was waiting on. Now the two cannot disagree, because
    /// they are the same word.
    case blockedOnReply(UnsafeMutablePointer<Process>?)
    case terminated
}
