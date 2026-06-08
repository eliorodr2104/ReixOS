//
//  Client.swift
//  ReixOS
//
//  Client-side stub for the Process Server: a human-level API over the IPC.
//

/// Result of a spawn request: the new pid and (if returned) a cap to it.
public struct SpawnedProcess {
    public let pid: UInt32
    public let cap: UInt32?
}


public struct ProcessServerClient {

    let endpoint: UInt32

    public init(endpoint: UInt32) { self.endpoint = endpoint }

    /// Connect by resolving `.processServer` through the Name Server.
    public init?(via nameServer: NameServerClient) {
        guard let cap = nameServer.lookup(.processServer) else { return nil }
        self.endpoint = cap
    }

    /// Ask the Process Server to spawn a program; returns its pid (+ cap).
    public func spawn(_ program: ProgramID) -> SpawnedProcess? {
        let response = call(handle: endpoint, message: ProcessServerOperation.spawn.message(for: program))

        guard response.message.tag.label == ProcessServerResponse.ok.rawValue else {
            return nil
        }

        return SpawnedProcess(pid: response.message.words[0], cap: response.grantedCap)
    }
}
