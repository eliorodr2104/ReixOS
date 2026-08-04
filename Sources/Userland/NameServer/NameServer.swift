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
          request  : inout ReceivedMessage
    ) {

        print("[ NS    ] badge request:", terminator: " ")
        printDec(UInt64(request.identity))

        switch operation {

            case .lookup:
                let id = Services(rawValue: request.message.words[0])

                if let id, let handle = servicesTable[Int(id.rawValue)] {
                    _ = reply(message: NameServerResponse.ack.message, grant: handle)

                } else { _ = reply(message: NameServerResponse.errorLookup.message) }

            case .register:
                register(&request)
        }
    }

    private mutating func register(_ request: inout ReceivedMessage) {

        guard request.session == NameServerSession.registrar else {
            print("[ NS    ] register refused: not a registrar capability")
            return
        }

        guard let id = Services(rawValue: request.message.words[0]) else {
            print("[ NS    ] register refused: unknown service")
            return
        }

        guard request.grantedCap != nil else {
            print("[ NS    ] register refused: no endpoint granted")
            return
        }

        if let stale = servicesTable[Int(id.rawValue)] { _ = capDrop(stale) }

        servicesTable[Int(id.rawValue)] = request.takeGrant()
    }
}
