//
//  ServiceRuntime.swift
//  ReixOS
//
//  Boots a process from its seeded capabilities: attaches the console, publishes
//  the service endpoint per its manifest, then runs the receive loop. `launch`
//  is the matching spawner side, forwarding the caller's ambient set to a child.
//

import ReixABI

public enum ServiceRuntime {

    public static func run<S: Service>(_ type: S.Type) -> Never {
        let environment = Runtime.bootstrap()
        let endpoint    = spawnEndpoint()

        publish(S.manifest, endpoint: endpoint, environment: environment)

        var service = S(environment: environment, endpoint: endpoint)
        service.run()

        while true { yield() }
    }

    private static func publish(
        _ manifest   : ServiceManifest,
          endpoint   : UInt32,
          environment: Environment
    ) {
        switch manifest.provides {
            case .none:
                break

            case .parent:
                if let parent = parentEndpoint() {
                    _ = send(
                        handle     : parent,
                        message    : BootMessage.announce.message,
                        grant      : endpoint,
                        grantRights: [.send, .grant]
                    )
                }

            case .nameServer(let service):
                if let nameServer = environment.nameServer {
                    _ = send(
                        handle     : nameServer,
                        message    : NameServerOperation.register.message(for: service),
                        grant      : endpoint,
                        grantRights: [.send, .grant]
                    )
                }
        }
    }
}

@inline(__always)
public func launch(
    _ path       : StaticString,
      environment: Environment
) -> SpawnResult {
    
    withUnsafeTemporaryAllocation(
        of      : CapGrant.self,
        capacity: 8
    ) { buffer in
        
        var count = 0

        if let console = environment.console {
            buffer[count] = CapGrant(source: console, slot: BootCap.console.rawValue, rights: [.send, .grant])
            count += 1
        }

        if let nameServer = environment.nameServer {
            buffer[count] = CapGrant(source: nameServer, slot: BootCap.nameServer.rawValue, rights: [.send, .grant])
            count += 1
        }

        if let spawn = environment.spawn {
            buffer[count] = CapGrant(source: spawn, slot: BootCap.spawn.rawValue, rights: [.spawn, .grant])
            count += 1
        }

        return spawnProcess(path: path, grants: buffer.baseAddress!, count: count)
    }
}
