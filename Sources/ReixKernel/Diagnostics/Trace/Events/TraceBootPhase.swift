//
//  TraceBootPhase.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/08/2026.
//


/// Which subsystem had just finished coming up, carried in
/// `TraceCode.bootPhase`'s `info`.
///
/// The ids are the host decoder's name table, so they are fixed independently
/// of `Kernel.boot`'s statement order: a phase that stops existing leaves a gap
/// rather than renumbering the ones after it.
enum TraceBootPhase {

    static let ppmReady    : UInt16 = 1
    static let vmmReady    : UInt16 = 2
    static let heapReady   : UInt16 = 3
    static let gicReady    : UInt16 = 4
    static let fsReady     : UInt16 = 5
    static let pmReady     : UInt16 = 6
    static let schedReady  : UInt16 = 7
    static let ipcReady    : UInt16 = 8
    static let syscallReady: UInt16 = 9
    static let timerOn     : UInt16 = 10

    /// The last kernel statement before `eret` into EL0.
    static let firstUser: UInt16 = 11
}
