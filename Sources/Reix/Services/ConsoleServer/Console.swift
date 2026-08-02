//
//  Console.swift
//  ReixOS
//
//  Created by Eliomar on 31/07/2026.
//


public enum Console {

    nonisolated(unsafe) static var client: ConsoleClient? = nil

    public static func attach(console endpoint: UInt32) {
        client = ConsoleClient(console: endpoint)
    }
}