//
//  NameServer.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix


public struct NameServer: Service {

    public static let manifest = ServiceManifest(provides: .parent)

    private var servicesTable = InlineArray<3, UInt32?>(repeating: nil)
    private let endpoint: UInt32

    public var serviceEndpoint: UInt32 { endpoint }


    public init(
        environment: Environment,
        endpoint   : UInt32
    ) {
        self.endpoint = endpoint
    }


    public mutating func handle(
        _ operation: NameServerOperation,
          request  : ReceivedMessage
    ) {

        print("[ NS    ] badge request:", terminator: " ")
        print(String(UInt64(request.badge)))

        let id = Services(rawValue: request.message.words[0])

        switch operation {

            case .lookup:
                if let id, let handle = servicesTable[Int(id.rawValue)] {
                    _ = reply(message: NameServerResponse.ack.message, grant: handle)

                } else { _ = reply(message: NameServerResponse.errorLookup.message) }

            case .register:
                if let id {
                    servicesTable[Int(id.rawValue)] = request.grantedCap

                } else { _ = reply(message: NameServerResponse.errorRegister.message) }
        }
    }
}
