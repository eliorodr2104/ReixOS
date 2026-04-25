//
//  GlobalLoggers.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/04/2026.
//

typealias SystemLogger = Logger<UARTQemu>
private let _logger = SystemLogger(driver: UARTQemu())

public func kprint(_ s: String) {
    _logger.kprint(s)
}

public func kprint() {
    _logger.kprint()
}

public func kprint(_ val: UInt64) {
    _logger.kprint(val)
}


public func kprintf(_ fmt: String, _ a: UInt64) {
    _logger.kprintf(fmt, a)
}

public func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64) {
    _logger.kprintf(fmt, a, b)
}

public func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64, _ c: UInt64) {
    _logger.kprintf(fmt, a, b, c)
}

public func kprintf(_ fmt: String, _ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) {
    _logger.kprintf(fmt, a, b, c, d)
}


