//
//  ProcessServer.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix

public struct ProcessServer: UserlandService {

    private let endpoint     : UInt32
    private let nameServerCap: UInt32

    public var serviceEndpoint: UInt32 { endpoint }


    init() {
        print("[ SERVE ] Hi, Process Server is running!\n")

        guard let parentHandle = parentEndpoint() else {
            print("[ SERVE ] no parent endpoint!")
            exit(code: 1)
        }

        _ = receive(handle: parentHandle)              // 1: spawn-cap (installata in tabella)
        let bootNs = receive(handle: parentHandle)     // 2: NS-cap

        guard let nsCap = bootNs.grantedCap else {
            print("[ SERVE ] no NS cap")
            exit(code: 1)
        }
        self.nameServerCap = nsCap
        print("[ SERVE ] holding spawn-cap and NS-cap")

        // Crea l'endpoint di servizio e si registra in rubrica come .processServer.
        self.endpoint = spawnEndpoint()
        _ = send(
            handle     : nsCap,
            message    : NameServerOperation.register.message(for: .processServer),
            grant      : endpoint,
            grantRights: [.send, .grant]
        )
        print("[ SERVE ] Process Server register")

        // Demo: lancia un Child e gli passa una cap NS badgiata.
        let child = spawnProcess(path: "Child.elf")
        if let childNs = derive(handle: nsCap, badge: 1, rights: [.send, .grant]) {
            _ = send(
                handle     : child.handle,
                message    : NameServerResponse.ok.message,
                grant      : childNs,
                grantRights: [.send]
            )
            print("[ SERVE ] Child send grant")
        }
    }


    public func handle(_ operation: ProcessServerOperation, request: ReceivedMessage) {

        switch operation {

            case .spawn:
                if let program = ProgramID(rawValue: request.message.words[0]) {
                    let resultSpawn = spawnProcess(path: program.tarPath)
                    _ = reply(
                        message: ProcessServerResponse.ok.message(
                            for: UInt32(truncatingIfNeeded: resultSpawn.pid)
                        ),
                        grant: resultSpawn.handle
                    )
                }
        }
    }
}
