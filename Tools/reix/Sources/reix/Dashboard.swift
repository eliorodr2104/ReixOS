//
//  Dashboard.swift
//  ReixOS
//

import Foundation
import ReixBuild
import SwiftTUI
import SwiftTUICLI

/// The build, drawn, when there is a terminal to draw it on.
///
/// Every cell is placed by SwiftTUI. The version this replaces composed each
/// row as a padded string and handed the result to a content-sized `VStack`, so
/// a 200 column terminal got a 72 column block in its top left corner and
/// nothing else. `.frame(maxWidth:maxHeight:)` on the root and a `Spacer` in
/// the phase band are what make the panel the whole screen instead.
struct Dashboard: View {
    @Environment(\.requestTermination) private var requestTermination

    var body: some View {
        DashboardPanel()
            .task {
                // The phase bodies block the thread they run on, so they cannot run
                // on the actor that has to redraw. Events come back the other way.
                let steps   = BuildState.shared.steps
                let sink    = EventSink { event in
                    DispatchQueue.main.async { MainActor.assumeIsolated { BuildState.shared.apply(event) } }
                }
                let ticking = Task { while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    BuildState.shared.tick()
                } }

                let ok = await Task.detached { await PhaseRunner.run(steps, into: sink) }.value
                ticking.cancel()
                BuildState.shared.finished(ok)
                _ = requestTermination()
            }
    }
}


extension Dashboard {

    /// Runs the build under the dashboard and reports whether it succeeded.
    ///
    /// Nothing is printed until the session has torn down: an `lld` error is
    /// the one thing on the screen a reader has to keep, and it must land on a
    /// terminal that is the shell's again, at the width the tool chose.
    @MainActor
    static func run(_ steps: [PhaseRunner.Step], options: BuildPipeline.Options, root: URL) async -> Bool {
        let state = BuildState.shared
        state.mode    = "\(options.bootMode) · \(options.release ? "release" : "debug")"
        state.version = version(at: root)
        state.start(steps, root: root)

        do {
            try await TerminalRunner.run(DashboardApp())
        } catch {
            // Nothing ran, so say what runs: the flat renderer needs none of
            // this and builds the same image.
            FileHandle.standardError.write(Data("dashboard: \(error), retry with --plain\n".utf8))
            return false
        }

        // Raw mode makes Ctrl-C a byte, not a signal: a stopped build ends with
        // nothing to show and no tool that said why. 1 would call that a break.
        let interrupted = !state.ok && state.failure == nil

        // The same visual language, two bands shorter, on the terminal the
        // shell owns again. An interrupted build has nothing to summarise.
        if !interrupted { print(SummaryCard.text(state)) }

        // Unbuffered stderr below would otherwise land first, and a buffer
        // nobody flushed is the report nobody gets to read.
        fflush(stdout)

        if let failure = state.failure { FileHandle.standardError.write(Data(failure.utf8 + [0x0A])) }
        if interrupted {
            FileHandle.standardError.write(Data("  interrupted\n".utf8))
            exit(130)
        }
        if state.ok { state.record().write(at: root) }
        return state.ok
    }

    /// The version, read out of the kernel source as text. The CLI is a host
    /// binary and `ReixKernel` is bare metal, so importing it is not an option.
    private static func version(at root: URL) -> String {
        let file = root.appending(path: "Sources/ReixKernel/Core/GlobalTypes.swift")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "?" }

        func number(_ name: String) -> String {
            guard let field = text.range(of: "static let \(name) = ") else { return "?" }
            return String(text[field.upperBound...].prefix(while: \.isNumber))
        }
        return "\(number("major")).\(number("minor")).\(number("patch"))"
    }
}


/// The scene. One window, no title bar of its own: the frame is the panel's.
struct DashboardApp: SwiftTUIRuntime.App {
    var body: some Scene {
        WindowGroup { Dashboard() }
    }
}


// MARK: - The panel

/// Two bands in one frame, filling whatever terminal it is given.
///
/// The phase band carries `maxHeight: .infinity`, so every row of slack a large
/// terminal offers goes there and the artifact band stays pinned to the bottom
/// rule. The title lives in the top rule, which no border modifier has a slot
/// for, so it is two overlays aligned to the frame's own corners rather than a
/// rule composed as text.
struct DashboardPanel: View {

    var body: some View {
        let state = BuildState.shared

        VStack(spacing: 0) {
            phases(state)
                .padding(EdgeInsets(top: 2, leading: 4, bottom: 1, trailing: 3))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().foregroundStyle(.separator)

            artifacts(state)
                .padding(EdgeInsets(top: 0, leading: 4, bottom: 1, trailing: 3))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Outset, not the default inset: an inset stroke reserves no cells and
        // the library reports occlusion on the first frame, before the size is
        // known, which lands on the terminal QEMU is about to take.
        .border(.separator, set: .rounded, placement: .outset)
        .overlay(alignment: .topLeading)  { Text(" reix ").foregroundStyle(.tint).offset(x: 2) }
        .overlay(alignment: .topTrailing) { Text(" \(state.mode) ").foregroundStyle(.muted).offset(x: -2) }
        .overlay(alignment: .bottomLeading)  { junction("├") }
        .overlay(alignment: .bottomTrailing) { junction("┤") }
    }

    /// Where the rule between the bands meets the frame. The border draws into
    /// the outermost cells of its content, so it lands on the `Divider`'s two
    /// end cells and writes `│` over them; an overlay draws after the border
    /// and is the only thing that can put the junction glyph back.
    private func junction(_ glyph: String) -> some View {
        Text(glyph).foregroundStyle(.separator).offset(y: -Self.artifactRows)
    }

    /// Two rows of artifacts, the bottom rule, and the outset border's own row:
    /// how far above the frame's last row the divider sits.
    private static let artifactRows = 4

    @ViewBuilder
    private func phases(_ state: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ReixOS \(state.version) · AArch64 · Embedded Swift")
                .foregroundStyle(.muted)
                .padding(.bottom, 1)

            ForEach(state.phases, id: \.self) { phase in
                let status = state.status[phase] ?? .waiting
                PhaseRow(phase: phase, status: status, live: state.live)

                if case .running(_, _, let now) = status {
                    let doing = now.isEmpty ? state.why[phase] ?? "" : now
                    if !doing.isEmpty {
                        Text("└ " + doing).foregroundStyle(.muted).padding(.leading, 5)
                    }
                }
            }
            tail(state)
        }
    }

    /// The slack under the phase rows, filled with what the running tool is
    /// writing. It is what a reader is waiting for during a compile, and it is
    /// the only band whose content a taller terminal gets more of.
    ///
    /// `GeometryReader` rather than a guessed row count: the region's height is
    /// whatever the phase rows left over, and it is the library that knows it.
    /// Muted and truncated, never wrapped: one arriving path must not reflow
    /// every row above it.
    @ViewBuilder
    private func tail(_ state: BuildState) -> some View {
        GeometryReader { proxy in
            let lines = Array(state.output.suffix(max(0, proxy.size.height)))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<lines.count, id: \.self) { row in
                    Text(Format.clip(lines[row], to: proxy.size.width))
                        .foregroundStyle(.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Four columns of fixed width and a `Spacer`, so the timings ride the
    /// right edge of a wide terminal instead of huddling with the sizes.
    @ViewBuilder
    private func artifacts(_ state: BuildState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtifactRow(
                name : "kernel",
                bytes: state.kernelBytes,
                was  : state.previous?.kernel,
                label: "elapsed",
                value: Format.seconds(state.total)
            )
            ArtifactRow(
                name : "initrd",
                bytes: state.initrdBytes,
                was  : state.previous?.initrd,
                label: state.previous == nil ? "" : "vs previous",
                value: Format.against(state.total, state.previous?.elapsed)
            )
        }
    }
}


/// One phase: its bullet, its name, whatever it has to say, and its clock.
private struct PhaseRow: View {
    let phase : ReixBuild.Phase
    let status: BuildState.Status
    let live  : Duration

    var body: some View {
        HStack(spacing: 0) {
            Text(mark).foregroundStyle(tone).frame(width: 3, alignment: .leading)
            Text(phase.rawValue).frame(width: 11, alignment: .leading)
            detail
            Spacer()
            Text(clock).foregroundStyle(.muted).frame(width: 6, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch status {
            case .running(let done, let total, _) where total > 0:
                ProgressView(value: Double(done), total: Double(total), barWidth: Format.bar) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(done)/\(total)")
                }
                .progressViewStyle(TrackBarStyle())

            case .finished(let summary, _): Text(summary).foregroundStyle(.muted)
            case .skipped (let because)   : Text("skipped, " + because).foregroundStyle(.muted)
            case .failed                  : Text("FAILED").foregroundStyle(.danger)
            default                       : EmptyView()
        }
    }

    private var mark: String {
        switch status {
            case .waiting : return "○"
            case .running : return "●"
            case .finished: return "✓"
            case .skipped : return "·"
            case .failed  : return "✗"
        }
    }

    private var tone: SemanticShapeStyle {
        switch status {
            case .waiting, .skipped: return .muted
            case .running          : return .tint
            case .finished         : return .success
            case .failed           : return .danger
        }
    }

    private var clock: String {
        switch status {
            case .running                 : return Format.seconds(live)
            case .finished(_, let elapsed): return Format.seconds(elapsed)
            default                       : return ""
        }
    }
}


/// One artifact and one timing, on the same row: the two things a reader
/// compares against the build before this one.
private struct ArtifactRow: View {
    let name : String
    let bytes: Int?
    let was  : Int?
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 0) {
            Text(name).frame(width: 9, alignment: .leading)
            Text(bytes.map(Format.size) ?? "—").foregroundStyle(.muted).frame(width: 9, alignment: .leading)
            Text(Format.change(bytes, was)).foregroundStyle(.muted).frame(width: 14, alignment: .leading)
            Spacer()
            Text(label).foregroundStyle(.muted).frame(width: 14, alignment: .leading)
            Text(value).frame(width: 8, alignment: .leading)
        }
    }
}


/// The bar from the mockup: filled cells in the tint, the rest in the separator
/// colour, and the count beside it rather than on a line of its own.
///
/// The built-in `LinearProgressViewStyle` stacks its header above the track and
/// draws the empty half with `─`, so a row of the phase band would be two rows
/// tall. This is the style system doing what it is for; the primitive, its
/// fraction and its label slots are still the library's.
struct TrackBarStyle: ProgressViewStyle {
    func makeBody(configuration: ProgressViewStyleConfiguration) -> some View {
        let width  = max(1, configuration.barWidth)
        let filled = Int((min(max(configuration.fractionCompleted ?? 0, 0), 1) * Double(width)).rounded())

        HStack(spacing: 0) {
            Text(String(repeating: "█", count: filled)).foregroundStyle(.tint)
            Text(String(repeating: "░", count: width - filled)).foregroundStyle(.separator)
            if let value = configuration.currentValueLabel {
                value.foregroundStyle(.muted).padding(.leading, 2)
            }
        }
    }
}


// MARK: - The card left in scrollback

/// What a finished build leaves behind once the alternate screen is gone.
///
/// Rendered by `RenderOnce`, the library's one-shot path: the same views, the
/// same border and the same overlaid title as the panel, drawn to a string on
/// the terminal the shell owns again. Rejected: printing the flat renderer's
/// lines, which is what the panel exists to replace.
enum SummaryCard {

    @MainActor
    static func text(_ state: BuildState) -> String {
        RenderOnce.render(Card(state: state)).trimmingCharacters(in: .newlines)
    }

    private struct Card: View {
        let state: BuildState

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.self) { Text($0) }
            }
            .padding(EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3))
            .frame(minWidth: 39, alignment: .leading)
            .fixedSize()
            // Outset, not the default inset: an inset stroke draws over the
            // content's own outer ring, which at this size leaves no interior.
            .border(.separator, set: .rounded, placement: .outset)
            .overlay(alignment: .topLeading)  { Text(" reix ").foregroundStyle(.tint).offset(x: 2) }
            .overlay(alignment: .top)         { Text(" \(state.mode) ").foregroundStyle(.muted) }
            .overlay(alignment: .topTrailing) { Text(" \(Format.seconds(state.total)) ").foregroundStyle(.muted).offset(x: -2) }
            .padding(.leading, 2)
        }

        /// The phases' own summaries, not a second opinion about them: the same
        /// words the flat renderer prints, two per line instead of one.
        private var lines: [String] {
            if let phase = state.failedPhase { return ["✗ \(phase.rawValue) failed"] }

            let counts = [state.summary(.compile), state.summary(.userland)]
                .compactMap { $0 }
                .joined(separator: " · ")
            return [counts, state.summary(.image) ?? ""].filter { !$0.isEmpty }
        }
    }
}


// MARK: - Numbers as text

enum Format {

    /// Wide enough to read a thirteen step phase off, narrow enough to leave
    /// the summary column room on an eighty column terminal.
    static let bar = 24

    static func seconds(_ duration: Duration) -> String {
        let milliseconds = duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return String(format: "%.1fs", Double(milliseconds) / 1000)
    }

    /// A compiler path is longer than any terminal. Wrapping it would push every
    /// row of the tail around each time one arrived, so it is cut instead.
    static func clip(_ line: String, to width: Int) -> String {
        guard width > 0     else { return "" }
        guard line.count > width else { return line }
        return String(line.prefix(width - 1)) + "…"
    }

    static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : "\((bytes + 512) / 1024) KiB"
    }

    /// A first build has nothing to subtract from, so it says nothing rather
    /// than claiming a delta of zero it did not measure.
    static func change(_ now: Int?, _ before: Int?) -> String {
        guard let now, let before else { return "" }
        guard now != before else { return "= unchanged" }
        return (now > before ? "▲ " : "▼ ") + size(abs(now - before))
    }

    static func against(_ now: Duration, _ before: Double?) -> String {
        guard let before else { return "" }
        let milliseconds = now.components.seconds * 1000
            + now.components.attoseconds / 1_000_000_000_000_000
        return String(format: "%+.1fs", Double(milliseconds) / 1000 - before)
    }
}
