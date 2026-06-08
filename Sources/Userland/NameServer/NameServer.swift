//
//  NameServer.swift
//  ReixOS
//
//  Created by Eliomar on 08/06/2026.
//

import Reix


public struct NameServer {
    
    private var servicesTable = InlineArray<3, UInt32?>(repeating: nil)
    private let endpoint: UInt32
    
    
    init() {
        self.endpoint = spawnEndpoint()
    }
    
    
    public mutating func run() {
        
        _ = send(
            handle     : parentEndpoint()!,
            message    : NameServerResponse.ok.message,
            grant      : endpoint,
            grantRights: [.send, .grant, .derive]
        )
                
        while true {
            
            let request = receive(handle: endpoint)
            
            print("[ NS    ] badge request:", terminator: " ")
            print(String(UInt64(request.badge)))
            
            let id = Services(rawValue: request.message.words[0])
            
            guard let operation = NameServerOperation(rawValue: request.message.tag.label) else {
                return
            }
            
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
}
