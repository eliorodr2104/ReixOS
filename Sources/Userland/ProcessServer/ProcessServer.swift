//
//  ProcessServer.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix

public struct ProcessServer: Service {

    public static let manifest = ServiceManifest(
        provides: .nameServer(.processServer)
    )

    private let endpoint   : UInt32
    private let environment: Environment

    public var serviceEndpoint: UInt32 { endpoint }


    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint    = endpoint
        self.environment = environment

        print("[ SERVE ] Process Server running, launching Child")
        _ = launch("Child.elf", environment: environment)
    }


    public func handle(
        _ operation: ProcessServerOperation,
          request  : ReceivedMessage
    ) {

        switch operation {

            case .spawn:
                if let program = ProgramID(rawValue: request.message.words[0]) {
                    let result = launch(program.tarPath, environment: environment)
                    _ = reply(
                        message: ProcessServerResponse.ok.message(
                            for: UInt32(truncatingIfNeeded: result.pid)
                        ),
                        grant: result.handle
                    )
                }
        }
    }
}
