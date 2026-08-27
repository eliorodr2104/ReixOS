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

    /// The right to tell the machine what time it is.
    ///
    /// Reading the clock needs nothing: what time it is is not a secret, and a
    /// process that could not ask would have to be told by somebody who could.
    /// *Setting* it is authority, because every timestamp written afterwards
    /// depends on it and a clock moved backwards makes an ordered record lie.
    case clock

    /// The right to stop the machine.
    ///
    /// The last thing anybody does, and the only authority whose exercise
    /// nobody sees the result of. It is a capability for the same reason the
    /// clock is: a process that could do it by asking would be a process that
    /// could do it by mistake.
    case power
}
