//
//  NameServer.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix


public struct NameServer: Service {

    public static let manifest = ServiceManifest(provides: .parent)

    /// One slot per name. The literal has to match `Services.count`, which the
    /// bounds check below is there to survive: adding a case used to write past
    /// the end of this table and take the whole system down with it.
    ///
    /// One name, at the moment. Everything else this machine runs is handed over
    /// rather than looked up.
    private var servicesTable = InlineArray<1, UInt32?>(repeating: nil)
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
                let id = Services(rawValue: request.message.words[0]).flatMap(slot)

                if let id, let handle = servicesTable[id] {
                    _ = reply(message: NameServerResponse.ack.message, grant: handle)

                } else { _ = reply(message: NameServerResponse.errorLookup.message) }

            case .register:
                register(&request)
        }
    }

    private mutating func register(_ request: inout ReceivedMessage) {

        // Which name this capability may publish, off the badge the kernel
        // stamped. Not off the message: a process cannot say which service it is
        // any more than it can say who it is.
        guard let allowed = NameServerSession.service(of: request.session) else {
            print("[ NS    ] register refused: not a registrar capability")
            return
        }

        guard let service = Services(rawValue: request.message.words[0]),
              let id = slot(service)
        else {
            print("[ NS    ] register refused: unknown service")
            return
        }

        // One capability, one name. A registrar used to be a general licence,
        // so a service that had been given one to publish itself could publish
        // anything - including standing in for something already there.
        guard service == allowed else {
            print("[ NS    ] register refused: that capability does not publish that name")
            return
        }

        guard request.grantedCap != nil else {
            print("[ NS    ] register refused: no endpoint granted")
            return
        }

        // Once. A name that could be republished is a name whose meaning is
        // whatever the last writer said, and there is no moment after boot when
        // a service legitimately becomes a different process. Replacing one
        // would be an administrative act needing an authority of its own, on the
        // pattern of the disk's warden - and nothing has needed it yet.
        guard servicesTable[id] == nil else {
            print("[ NS    ] register refused: that name is already answered")
            return
        }

        servicesTable[id] = request.takeGrant()
    }


    /// The row a name lives in, or nil when this build of the Name Server is
    /// older than the name being asked for.
    private func slot(_ service: Services) -> Int? {
        let index = Int(service.rawValue)
        return index < servicesTable.count ? index : nil
    }
}
