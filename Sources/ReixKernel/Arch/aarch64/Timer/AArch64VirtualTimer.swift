//
//  HardwareTimer.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/04/2026.
//

public struct AArch64VirtualTimer: HardwareTimerInterface, Loggable {
    
    public static let nameLog : StaticString = "[TIM ]"
    public static let logLevel: LogLevel     = .info

    /// Brings this core's timer up: first deadline armed, `CNTV_CTL_EL0` set.
    ///
    /// Every core runs this once for itself. `CNTV_CTL_EL0` and `CNTV_CVAL_EL0`
    /// are banked per core, so no core can be armed on another's behalf.
    public static func enable() {
        enable_core_timer()

        Self.boot("Virtual Timer enabled.")
    }


    /// Moves this core's deadline one tick interval on. Never enables anything.
    public static func rearm() {
        rearm_core_timer()
    }


    /// Free-running virtual counter, `CNTVCT_EL0`.
    ///
    /// The only sub-tick clock the kernel has: `RoundRobin.systemTicks`
    /// moves in 10 ms steps, this one in ~16 ns steps on QEMU virt.
    /// Monotonic, and 64 bits at 62.5 MHz outlast any plausible uptime.
    @_transparent
    public static func counter() -> UInt64 {
        read_virtual_counter()
    }


    /// The same counter read without the `isb` that precedes `counter()`.
    ///
    /// That barrier exists so two stamps taken around a region of work cannot
    /// be speculated out of it, which is what a measurement needs and what a
    /// log timestamp does not: nothing subtracts one log stamp from another,
    /// and a full pipeline flush per line is a real cost on the log path.
    @_transparent
    public static func counterUnordered() -> UInt64 {
        read_virtual_counter_unordered()
    }


    /// Counter frequency in Hz, `CNTFRQ_EL0`: what a counter delta has to
    /// be divided by to become a duration. ~62.5 MHz on QEMU virt.
    @_transparent
    public static func frequency() -> UInt64 {
        read_counter_frequency()
    }
}
