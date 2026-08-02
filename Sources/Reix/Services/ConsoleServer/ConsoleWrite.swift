//
//  ConsoleWrite.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


/// Outcome of handing one byte to the console server.
public enum ConsoleWrite {

    /// The byte is queued in the ring, the server will write it out.
    case accepted

    /// The ring is full and the server is not draining it fast enough. The byte
    /// was *not* queued, print it another way rather than waiting for a slot.
    case backpressure

    /// The server holds no ring for this client, the registration was refused
    /// or dropped. Nothing will ever drain the ring, so this client is useless.
    case unregistered
}
