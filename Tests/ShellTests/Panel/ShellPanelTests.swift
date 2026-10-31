//
//  ShellPanelTests.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import Testing
import ReixABI
import ShellLanguage

private func painted(
    _ panel: ShellPanel,
      columns: UInt16 = 40,
      rows: UInt16 = 6
) -> (lines: [String], geometry: ShellPanelGeometry?, spans: [ReixTextSurfaceStyleSpan]) {
    var bytes = [UInt8](repeating: 0, count: ShellPanelPainter.byteCapacity)
    var spans = [ReixTextSurfaceStyleSpan](
        repeating: ReixTextSurfaceStyleSpan(offset: 0, length: 1, role: .plain)!,
        count: ShellPanelPainter.spanCapacity
    )
    var geometry: ShellPanelGeometry?
    bytes.withUnsafeMutableBufferPointer { text in
        spans.withUnsafeMutableBufferPointer { style in
            geometry = ShellPanelPainter.paint(
                panel,
                columns: columns,
                rows: rows,
                into: text.baseAddress!,
                spans: style.baseAddress!
            )
        }
    }
    guard let geometry else { return ([], nil, []) }
    let text = String(decoding: bytes[0..<geometry.byteCount], as: UTF8.self)
    return (text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            geometry,
            Array(spans[0..<geometry.spanCount]))
}

private func sample() -> ShellPanel {
    var panel = ShellPanel(title: "fileSystem")
    panel.append(ShellPanelRow(name: "read", detail: "Text", summary: "the first bytes of a file", role: .command))
    panel.append(ShellPanelRow(name: "remove", detail: "Void", summary: "take it away", sensitive: true, role: .command))
    panel.append(ShellPanelRow(name: "rename", detail: "Void", summary: "rename it, or move it", role: .command))
    return panel
}

@Suite("Shell panel")
struct ShellPanelTests {

    @Test("The box closes on every row, whatever is in it")
    func boxIsSquare() {
        let drawn = painted(sample())
        #expect(drawn.geometry?.rows == 5)
        #expect(drawn.lines.count == 5)
        // The box is drawn one column inside what it declares, so a full row
        // never wraps on its own.
        #expect(drawn.geometry?.columns == 40)
        for line in drawn.lines {
            #expect(line.count == 39, "row is not the width of the box: \(line)")
        }
        #expect(drawn.lines[0].hasPrefix("┌─ fileSystem "))
        #expect(drawn.lines[0].hasSuffix("┐"))
        #expect(drawn.lines[4].hasPrefix("└─ the first bytes of a file"))
        #expect(drawn.lines[4].hasSuffix("┘"))
    }

    @Test("The foot says what the selected row is about, and the selection moves")
    func selectionAndFooter() {
        var panel = sample()
        panel.step(1)
        let drawn = painted(panel)
        #expect(drawn.lines[4].hasPrefix("└─ take it away"))

        panel.step(-1)
        #expect(painted(panel).lines[4].hasPrefix("└─ the first bytes of a file"))

        // Selecting wraps rather than stopping, which is what a list of a few
        // does.
        panel.step(-1)
        #expect(panel.selected == 2)
    }

    @Test("A row that changes something is marked")
    func sensitiveRow() {
        let drawn = painted(sample())
        #expect(drawn.lines[2].contains("remove"))
        #expect(drawn.lines[2].contains("!"))
        #expect(!drawn.lines[1].contains("!"))
    }

    @Test("The selected row is one span, the others colour their name")
    func spans() {
        let drawn = painted(sample())
        #expect(drawn.spans.contains { $0.role == .selection })
        #expect(drawn.spans.contains { $0.role == .command })
        #expect(drawn.spans.contains { $0.role == .editorChrome })
        #expect(drawn.spans.count <= ShellPanelPainter.spanCapacity)

        // Overlay spans travel under the same rule as any other: sorted and
        // apart.
        var previousEnd = 0
        for span in drawn.spans {
            #expect(Int(span.offset) >= previousEnd)
            previousEnd = Int(span.offset) + Int(span.length)
        }
    }

    @Test("Rows that do not fit are counted, and the foot says so")
    func truncation() {
        var panel = ShellPanel(title: "many")
        for name in [
            "one", "two", "three", "four", "five", "six", "seven", "eight",
            "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        ] {
            name.withCString { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: name.utf8.count) { bytes in
                    panel.append(ShellPanelRow(bytes: bytes, count: name.utf8.count, detail: "Void"))
                }
            }
        }
        #expect(panel.count == ShellPanel.rowCapacity)
        #expect(panel.truncated)
        // The foot says where the selection is in the whole list, which is
        // how it says there is more of it than the box shows.
        #expect(painted(panel).lines.last?.contains("1 of 14") == true)
    }

    @Test("A terminal with no room for a box still gets the names")
    func linearProfile() {
        let narrow = painted(sample(), columns: 18, rows: 6)
        #expect(narrow.geometry?.rows == 1)
        #expect(narrow.lines.count == 1)
        #expect(narrow.lines[0].contains("read"))
        #expect(narrow.lines[0].contains("remove"))

        let short = painted(sample(), columns: 40, rows: 2)
        #expect(short.geometry?.rows == 1)
    }

    @Test("The same box shows what a command is, not only what fits")
    func documentationContent() {
        let descriptor = ShellCommandDescriptor(
            code     : 0,
            verb     : "remove",
            signature: TypedShellSignature(namespace: "fileSystem", name: "remove", TypedShellParameter("at")),
            capability: .container,
            sensitive: true,
            summary  : "take it away"
        )
        let drawn = painted(ShellPanel.documentation(descriptor))
        let joined = drawn.lines.joined(separator: "\n")
        #expect(joined.contains("remove"))
        #expect(joined.contains("at"))
        #expect(joined.contains("answers"))
        #expect(joined.contains("the disk"))
        #expect(joined.contains("container"))
    }

    @Test("And what a value is made of")
    func memberContent() {
        let drawn = painted(ShellPanel.members(of: .entry, title: "Entry"))
        let joined = drawn.lines.joined(separator: "\n")
        #expect(joined.contains("name"))
        #expect(joined.contains("isFolder"))
    }
}
