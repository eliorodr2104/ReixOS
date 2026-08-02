//
//  ServiceRuntime.swift
//  ReixOS
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
            case .none: break

            case .parent:
                if let parent = parentEndpoint() {
                    _ = send(
                        handle     : parent,
                        message    : BootMessage.announce.message,
                        grant      : endpoint,
                        grantRights: [.send, .grant, .derive]
                    )
                }

            case .nameServer(let service):
                guard let registrar = environment.nameServerRegistrar else {
                    print("[ SERVE ] cannot publish: no Name Server registrar capability")
                    return
                }

                _ = send(
                    handle     : registrar,
                    message    : NameServerOperation.register.message(for: service),
                    grant      : endpoint,
                    grantRights: [.send, .grant]
                )
        }
    }
}

/// Spawn `path` seeded with the caller's ambient capabilities.
///
/// `registrar` is taken as an argument and never read out of `environment`,
/// which is the whole reason it lives in a slot of its own. Ambient
/// capabilities are inherited: whatever the caller has, its children get. That
/// is right for the console and for name *lookup* and wrong for the authority
/// to publish a name, so delegating it has to be an act at the call site a
/// service seeded with a registrar still launches ordinary children.
@inline(__always)
public func launch(
    _ path       : StaticString,
      environment: Environment,
      registrar  : UInt32? = nil
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

        if let registrar {
            buffer[count] = CapGrant(source: registrar, slot: BootCap.nameServerRegistrar.rawValue, rights: [.send])
            count += 1
        }

        return spawnProcess(path: path, grants: buffer.baseAddress!, count: count)
    }
}
