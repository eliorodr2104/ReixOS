//
//  IPCInterface.swift
//  ReixOS
//
//  Created by Eliomar on 30/05/2026.
//

public protocol IPCInterface {
    mutating func send()      // Send mess, block if not receive the mess
    
    mutating func receive()   // wait, block if not send mess
    
    mutating func call()      // send + wait-reply, is atomic
    
    mutating func reply()     // Server respond to call process
    
    mutating func replyRecv() // reply + receive fuse (server loop)
}
