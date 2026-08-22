//
//  TerminalOperation.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

/// What a client asks the terminal for.
public enum TerminalOperation: UInt32, IPCLabel {

    /// Hand over the page the server will write lines into. One page, granted
    /// with the request.
    case register

    /// Ask whether this caller is registered.
    ///
    /// A register carries a capability, and a message that carries one has no
    /// reply, so the acknowledgement is a question of its own. Same shape as the
    /// console client's, which confirms with a flush.
    case status

    /// Write the prompt sitting in the registered page, then block until a line
    /// is ready and answer how many bytes it holds.
    ///
    /// The prompt travels in and the line travels back out through the same
    /// page: four words carry sixteen bytes and a line is up to a hundred and
    /// twenty-eight, so the message says how many rather than what.
    ///
    /// The prompt is written by the terminal and not by the caller for an
    /// ordering reason, not a tidiness one. The console drains its clients'
    /// rings in rotation, so two processes writing around the same moment do
    /// not come out in the order they wrote. Prompt and echo belong to one
    /// line, so one process has to write both, and it has to be the one that
    /// owns the echo.
    case readLine

    public func message(word0: UInt32 = 0) -> Message {
        var words = InlineArray<4, UInt32>(repeating: 0)
        words[0] = word0

        return Message(tag: MessageTag(self, length: 1), words: words)
    }
}


/// What a terminal request answers.
public enum TerminalStatus: UInt32 {
    case ok           = 0
    case unregistered = 1
    case refused      = 2
}
