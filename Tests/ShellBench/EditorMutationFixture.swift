//
//  EditorMutationFixture.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/08/2026.
//

import ReixABI
import ShellLanguage

/// Keeps setup outside the timed region and alternates one insertion with its
/// inverse backspace. Each step includes the real post-edit layout and frame
/// construction while preserving a stable 8 KiB workload indefinitely.
struct EditorMutationFixture: ~Copyable {
    private var editor    = ShellLineEditor()
    private var sequence  : UInt32
    private let baseCount : Int
    private var inserted  = false

    init(
        bytes       : [UInt8],
        movesFromEnd: Int,
        columns     : UInt16 = 80,
        rows        : UInt16 = 24
    ) {
        precondition(movesFromEnd >= 0)
        guard let next = seedEditor(&editor, bytes: bytes) else {
            fatalError("ShellBench fixture seed was refused")
        }
        sequence = next

        if columns != 80 || rows != 24 {
            guard editor.apply(
                ReixInputRecord(
                    kind: .resize,
                    sequence: sequence,
                    width: columns,
                    height: rows
                )!
            ).requiresPresentation else { fatalError("ShellBench fixture resize was refused") }
            sequence &+= 1
        }

        guard editor.withFrame({ _ in true }) else { fatalError("ShellBench fixture snapshot failed") }

        for index in 0..<movesFromEnd {
            guard editor.apply(benchmarkKey(.left, sequence: sequence)).requiresPresentation else {
                fatalError(
                    "ShellBench fixture cursor move was refused: requested=\(movesFromEnd) "
                        + "index=\(index) cursor=\(editor.cursor)"
                )
            }
            sequence &+= 1
        }

        guard editor.withFrame({ _ in true }) else { fatalError("ShellBench fixture metadata failed") }
        baseCount = bytes.count
    }

    mutating func step() -> Int {
        let update: ShellEditorUpdate
        if inserted {
            update = editor.apply(benchmarkKey(.backspace, sequence: sequence))
        } else {
            var byte = UInt8(ascii: "z")
            update = withUnsafePointer(to: &byte) {
                editor.apply(
                    ReixInputRecord(kind: .insert, sequence: sequence, bytes: $0, count: 1)!
                )
            }
        }
        sequence &+= 1
        guard update.requiresPresentation else { return 0 }
        inserted.toggle()

        var frameValue = 0
        guard editor.withFrame({ source in
            frameValue = Int(source.frame.cursorRow) + Int(source.frame.cursorColumn) + 1
            return true
        }) else { return 0 }

        let expected = baseCount + (inserted ? 1 : 0)
        return editor.count == expected ? expected + frameValue : 0
    }
}
