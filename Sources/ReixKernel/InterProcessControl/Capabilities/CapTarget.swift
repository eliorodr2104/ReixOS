//
//  CapTarget.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

public enum CapTarget: Equatable {
    case endpoint(UnsafeMutablePointer<Endpoint>)
    case shared  (UnsafeMutablePointer<SharedRegion>)
}
