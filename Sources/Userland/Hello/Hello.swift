//
//  Hello.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import Reix

/// The smallest thing that is a command rather than a test.
///
/// It prints and it ends, and that second half is what the others lack: `Child`
/// and `Child2` are two halves of a shared-memory exchange and block waiting for
/// each other, `Top` never returns on purpose. A shell needs at least one image
/// that behaves the way a command behaves.
///
/// It also stands as the demonstration of what a spawned program is given. The
/// console arrives, so this line is seen; nothing else does, and the attempt
/// below to have a child of its own is refused by the kernel and not by any
/// agreement this program keeps.
@_cdecl("_start")
public func main() {

    _ = Runtime.bootstrap()

    print("[ HELLO ] hello from a process that owns nothing but a console")

    let attempt = spawnProcess(path: "Hello.elf")

    if attempt.pid == UInt64.max {
        print("[ HELLO ] and it may not spawn children: the kernel refused")
    } else {
        print("[ HELLO ] unexpected: this process was allowed to spawn")
    }

    exit(code: 7)
}
