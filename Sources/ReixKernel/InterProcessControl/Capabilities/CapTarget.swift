//
//  CapTarget.swift
//  ReixOS
//
//  Created by Eliomar on 24/06/2026.
//

public enum CapTarget: Equatable {
    case endpoint(UnsafeMutablePointer<Endpoint>)
    case shared  (UnsafeMutablePointer<SharedRegion>)

    /// A buffer a device transfers into or out of. The same object as `shared`
    /// and deliberately a different case: holding this one is what entitles a
    /// process to learn the region's physical address, and holding a shared
    /// region never is.
    case dma     (UnsafeMutablePointer<SharedRegion>)
    case device  (DeviceRegion)

    /// A bus, from which windows and lines are carved. Never driven directly.
    case bus     (UnsafeMutablePointer<BusAuthority>)
    case interrupt(UnsafeMutablePointer<InterruptSet>)
    case profileControl
}
