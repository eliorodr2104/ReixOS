//
//  PanicFormatter.swift
//  ReixOS
//
//  Created by Eliomar on 22/08/2026.
//


/// Renders a `PanicReport` into a sequence of console lines.
///
/// Stateless by design so it can be swapped at compile time with
/// alternative formatters (e.g. JSON dump over UART, compact one-line
/// report for embedded targets without enough console real estate).
public protocol PanicFormatter {
    static func format(_ report: PanicReport)
}
