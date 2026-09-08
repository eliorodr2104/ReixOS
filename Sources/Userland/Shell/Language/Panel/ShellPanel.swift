//
//  ShellPanel.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI

/// One line of a panel: something named, what shape it is, and whether it
/// deserves a mark.
public struct ShellPanelRow {
    public static let nameCapacity = 32

    public private(set) var name  = InlineArray<32, UInt8>(repeating: 0)
    public private(set) var count = 0

    /// The column beside the name: a type, a receiver, whatever the row is
    /// about. Never a sentence; the footer is where sentences go.
    public let detail   : StaticString

    /// Marked, because carrying it out changes something that cannot be put
    /// back.
    public let sensitive: Bool

    /// How the name is painted, so a verb in a panel looks like a verb in a
    /// line.
    public let role     : ReixTextSurfaceStyleRole

    /// One line about this row, shown at the foot while it is the selected one.
    public let summary  : StaticString

    /// What to write after the name when this row is accepted, so the line
    /// reads as it should. The row carries it because the row is what gets
    /// accepted; nothing else has to be kept alive beside the box.
    public let suffix   : StaticString

    public init?(
        name     : StaticString,
        detail   : StaticString = "",
        summary  : StaticString = "",
        suffix   : StaticString = "",
        sensitive: Bool = false,
        role     : ReixTextSurfaceStyleRole = .plain
    ) {
        guard name.utf8CodeUnitCount > 0, name.utf8CodeUnitCount <= Self.nameCapacity else { return nil }
        self.detail = detail
        self.summary = summary
        self.suffix = suffix
        self.sensitive = sensitive
        self.role = role
        for index in 0..<name.utf8CodeUnitCount { self.name[index] = name.utf8Start[index] }
        self.count = name.utf8CodeUnitCount
    }

    public init?(
        bytes    : UnsafePointer<UInt8>,
        count    : Int,
        detail   : StaticString = "",
        summary  : StaticString = "",
        suffix   : StaticString = "",
        sensitive: Bool = false,
        role     : ReixTextSurfaceStyleRole = .plain
    ) {
        guard count > 0, count <= Self.nameCapacity else { return nil }
        self.detail = detail
        self.summary = summary
        self.suffix = suffix
        self.sensitive = sensitive
        self.role = role
        for index in 0..<count { self.name[index] = bytes[index] }
        self.count = count
    }

    public func withName<Result>(_ body: (UnsafePointer<UInt8>, Int) -> Result) -> Result {
        var storage = name
        return storage.span.withUnsafeBufferPointer { body($0.baseAddress!, count) }
    }
}

/// A box that shows rows, whatever the rows are about.
///
/// One component, filled by whoever opens it: the candidates that fit at the
/// cursor, what a command takes and does, what a value is made of. The panel
/// knows how to be a list with a title and a line at the foot, and nothing
/// about where its rows came from.
public struct ShellPanel {
    public static let rowCapacity = 6

    private var entries = InlineArray<6, ShellPanelRow?>(repeating: nil)

    /// What the box is showing, drawn in its top edge.
    public let title: StaticString

    public private(set) var count = 0

    /// Which row the selection sits on. Selecting is not accepting: nothing
    /// leaves this box until somebody says so.
    public private(set) var selected = 0

    /// How many rows there were in all, when more matched than fit.
    public private(set) var available = 0

    public init(title: StaticString) {
        self.title = title
    }

    public var isEmpty: Bool { count == 0 }

    public var truncated: Bool { available > count }

    public func row(at index: Int) -> ShellPanelRow? {
        guard index >= 0, index < count else { return nil }
        return entries[index]
    }

    public var selection: ShellPanelRow? { row(at: selected) }

    @discardableResult
    public mutating func append(_ row: ShellPanelRow?) -> Bool {
        guard let row else { return false }
        available += 1
        guard count < entries.count else { return false }
        entries[count] = row
        count += 1
        return true
    }

    /// Counts rows that exist but did not fit, so the box can say so.
    public mutating func note(missing: Int) {
        guard missing > 0 else { return }
        available += missing
    }

    public mutating func select(_ index: Int) {
        guard count > 0 else { selected = 0; return }
        selected = min(max(0, index), count - 1)
    }

    /// Moves the selection, wrapping, which is what a list of a few does.
    public mutating func step(_ delta: Int) {
        guard count > 0 else { selected = 0; return }
        var next = (selected + delta) % count
        if next < 0 { next += count }
        selected = next
    }
}
