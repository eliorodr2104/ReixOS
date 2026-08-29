//
//  TraceExporter.swift
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/08/2026.
//

import PackagePlugin
import Foundation

/// Writes a decoded trace block as a Chrome Trace Event file.
///
/// A viewer and not a format: the file this produces is opened by
/// `ui.perfetto.dev` or `chrome://tracing`, both of which run locally in a
/// browser tab. Nothing here is a ReixOS format, nothing is installed, and the
/// day it stops being useful the file goes without anything noticing.
///
/// The mapping is a straight one, because the kernel's records already have the
/// shape a timeline wants. `syscallExit` is the clearest case: it carries its
/// own duration, so one record is one complete slice and nothing has to be
/// paired up. What does need pairing is the schedule, rebuilt below from
/// consecutive `ctxSwitch` records.
///
/// Sampled stacks are deliberately left out. They are a profile and not a
/// timeline, they want a flame graph rather than lanes, and the format for that
/// is speedscope's. Putting them here would produce a wall of instants that
/// says less than the `--profile` view already prints.
extension TraceDecoder {

    static func export(_ block: TraceBlock, to path: String) {
        guard let origin = block.events.first?.ts else {
            Diagnostics.error("nothing to export: the block holds no events.")
            return
        }

        var out     = Writer(block: block, origin: origin)
        var samples = 0

        out.metadata()

        for event in block.events {
            switch event.code {
                case 0x0100: out.syscall(event)
                case 0x0201: out.instant(event, name: "idleEnter", lane: Writer.Lane.kernel)
                case 0x0202: out.instant(event, name: "idleExit",  lane: Writer.Lane.kernel)
                case 0x0300: out.instant(event, name: "ipcBlock",  lane: Writer.Lane.process)
                case 0x0301: out.instant(event, name: "ipcWake",   lane: Writer.Lane.process)
                case 0x0302: out.ipcTransfer(event)
                case 0x0400: out.instant(event, name: "preempt " + regionName(event.info), lane: Writer.Lane.process)
                case 0x0600: out.pmuSection(event)
                case 0x0700: out.bootPhase(event)
                case 0x0800: out.instant(event, name: "spawn",     lane: Writer.Lane.process)
                case 0x0802: out.instant(event, name: "exit",      lane: Writer.Lane.process)
                case 0x0900: out.interaction(event)

                // Names are metadata, and samples belong to a flame graph.
                case 0x0500, 0x0501: samples += 1
                case 0x0801: break

                default: out.instant(event, name: opName(event.code), lane: Writer.Lane.process)
            }
        }

        out.schedule()

        do {
            try out.finish().write(
                to: URL(fileURLWithPath: path),
                atomically: true,
                encoding: .utf8
            )

        } catch {
            Diagnostics.error("could not write \(path): \(error)")
            return
        }

        print("Wrote \(path) (\(out.count) events).")
        print("Open it at https://ui.perfetto.dev or chrome://tracing.")

        // The ring is one window, and the sampler fills it fast: at 100 Hz it
        // can leave a handful of slots for everything else, which reads in a
        // viewer as an empty timeline rather than as a full one of samples.
        guard samples > out.count else { return }

        print("")
        print("Note: \(samples) of the \(block.events.count) records in this window are stack")
        print("samples, which are a profile rather than a timeline and are left out here.")
        print("Capture with the sampling category off for a window of syscalls, context")
        print("switches and IPC instead, and read the samples with --profile.")
    }


    /// Accumulates the event array and the few numbers that go beside it.
    ///
    /// A string builder and not `JSONSerialization`: the output is a flat array
    /// of small objects with known keys, and building it by hand keeps the
    /// number formatting under control. Timestamps are microseconds with three
    /// decimals, which is the unit the format is defined in and finer than a
    /// 62.5 MHz counter can actually resolve.
    struct Writer {
        enum Lane { case kernel, process }

        private let block : TraceBlock
        private let origin: UInt64
        private let names : [UInt32: String]

        private var events = [String]()
        private var flows  = 0

        var count: Int { events.count }

        init(block: TraceBlock, origin: UInt64) {
            self.block  = block
            self.origin = origin
            self.names  = TraceDecoder.pidNames(block)
        }


        /// Microseconds since the first record in the block.
        private func at(_ ts: UInt64) -> String {
            let value = ts >= origin
                ? TraceDecoder.micros(ts - origin, freq: block.freq)
                : -TraceDecoder.micros(origin - ts, freq: block.freq)

            return String(format: "%.3f", value)
        }

        private func duration(_ counterUnits: UInt64) -> String {
            String(format: "%.3f", TraceDecoder.micros(counterUnits, freq: block.freq))
        }

        /// The lane an event is drawn in. Everything the kernel does on nobody's
        /// behalf lands in lane 0, which is where `pid` is already zero.
        private func lane(_ event: TraceEvent, _ kind: Lane) -> UInt32 {
            kind == .kernel ? 0 : event.pid
        }

        private static func escaped(_ text: String) -> String {
            var out = ""
            for character in text.unicodeScalars {
                switch character {
                    case "\"": out += "\\\""
                    case "\\": out += "\\\\"
                    case "\n": out += "\\n"
                    default:
                        if character.value < 0x20 {
                            out += String(format: "\\u%04x", character.value)
                        } else {
                            out.unicodeScalars.append(character)
                        }
                }
            }

            return out
        }


        /// Lane names, so the viewer shows `Shell.elf` instead of `pid 8`.
        mutating func metadata() {
            var lanes = Set(block.events.map(\.pid))
            lanes.insert(0)

            for pid in lanes.sorted() {
                let label = pid == 0
                    ? "kernel"
                    : (names[pid].map { "\($0) (pid \(pid))" } ?? "pid \(pid)")

                events.append("""
                {"ph":"M","name":"process_name","pid":\(pid),"tid":\(pid),\
                "args":{"name":"\(Self.escaped(label))"}}
                """)
                events.append("""
                {"ph":"M","name":"thread_name","pid":\(pid),"tid":\(pid),\
                "args":{"name":"\(Self.escaped(label))"}}
                """)
            }
        }


        /// One syscall, drawn as the interval it already knows it occupied.
        ///
        /// `a` is the duration and the record is written on the way out, so the
        /// slice starts at `ts - a`. Nothing is paired and nothing is guessed.
        mutating func syscall(_ event: TraceEvent) {
            let start = event.ts >= event.a ? event.ts - event.a : event.ts

            events.append("""
            {"ph":"X","name":"\(Self.escaped(TraceDecoder.syscallName(event.info)))",\
            "cat":"syscall","ts":\(at(start)),"dur":\(duration(event.a)),\
            "pid":\(event.pid),"tid":\(event.pid),"args":{"ret":\(event.b)}}
            """)
        }


        mutating func instant(_ event: TraceEvent, name: String, lane kind: Lane) {
            let target = lane(event, kind)

            events.append("""
            {"ph":"i","name":"\(Self.escaped(name))","cat":"event","s":"t",\
            "ts":\(at(event.ts)),"pid":\(target),"tid":\(target),\
            "args":{"a":\(event.a),"b":\(event.b),"info":\(event.info)}}
            """)
        }

        mutating func interaction(_ event: TraceEvent) {
            let points: [UInt16: String] = [1: "serialFirstByte", 2: "inputDecoded", 3: "shellConsumed", 4: "editorCompleted", 5: "parserCompleted", 6: "presentationRequested", 7: "uartAccepted"]
            let valid = event.a <= UInt64(UInt32.max) && event.b <= 0x00FF_FFFF && points[event.info] != nil
            let name  = valid ? points[event.info]! : "interactionInvalid"
            events.append("""
            {"ph":"i","name":"\(Self.escaped(name))","cat":"terminal","s":"t","ts":\(at(event.ts)),"pid":\(event.pid),"tid":\(event.pid),"args":{"correlation":\(event.a),"value":\(event.b),"valid":\(valid)}}
            """)
        }


        /// An IPC transfer as an arrow from sender to receiver.
        ///
        /// The one thing a timeline can show that a printed list cannot: which
        /// process woke which, drawn across the lanes.
        ///
        /// Each end is a slice of its own before it is an arrow endpoint, and
        /// that is not decoration: a flow has to be enclosed by a slice or the
        /// viewer has nothing to anchor it to and reports
        /// `FLOW_NO_ENCLOSING_SLICE`. The slices have **zero duration**, which
        /// is the honest width: the kernel records a transfer as an instant and
        /// nothing here knows how long it took.
        mutating func ipcTransfer(_ event: TraceEvent) {
            let from = UInt32(truncatingIfNeeded: event.a)
            let to   = UInt32(truncatingIfNeeded: event.b)

            flows += 1

            events.append("""
            {"ph":"X","name":"ipc to \(to)","cat":"ipc","ts":\(at(event.ts)),\
            "dur":0,"pid":\(from),"tid":\(from)}
            """)
            events.append("""
            {"ph":"s","id":\(flows),"name":"ipc","cat":"ipc","ts":\(at(event.ts)),\
            "pid":\(from),"tid":\(from)}
            """)

            events.append("""
            {"ph":"X","name":"ipc from \(from)","cat":"ipc","ts":\(at(event.ts)),\
            "dur":0,"pid":\(to),"tid":\(to)}
            """)
            events.append("""
            {"ph":"f","id":\(flows),"name":"ipc","cat":"ipc","bp":"e",\
            "ts":\(at(event.ts)),"pid":\(to),"tid":\(to)}
            """)
        }


        /// A bring-up milestone, on the kernel's own lane.
        ///
        /// Thread scope and not global: a global instant goes on a track the
        /// format gives no way to name, which the viewer then shows as
        /// "Unnamed SliceTrack". These are the kernel's events and they read
        /// better under the kernel.
        mutating func bootPhase(_ event: TraceEvent) {
            let name = TraceDecoder.phaseNames[event.info] ?? "phase#\(event.info)"

            events.append("""
            {"ph":"i","name":"\(Self.escaped(name))","cat":"boot","s":"t",\
            "ts":\(at(event.ts)),"pid":0,"tid":0}
            """)
        }


        mutating func pmuSection(_ event: TraceEvent) {
            events.append("""
            {"ph":"i","name":"pmuSection","cat":"pmu","s":"t","ts":\(at(event.ts)),\
            "pid":\(event.pid),"tid":\(event.pid),\
            "args":{"cycles":\(event.a),"instructions":\(event.b)}}
            """)
        }


        /// The schedule, rebuilt from consecutive context switches.
        ///
        /// Each switch says who left and who arrived, so the process that
        /// arrived owns the CPU until the next one. Drawn on a lane of its own
        /// rather than on each process's, because it answers a different
        /// question: not what a process did, but who had the machine.
        ///
        /// The last arrival gets no slice: the ring ends before it was
        /// relieved, and inventing an end for it would be inventing data.
        mutating func schedule() {
            let switches = block.events.filter { $0.code == 0x0200 }
            guard switches.count > 1 else { return }

            for index in 0..<(switches.count - 1) {
                let start   = switches[index]
                let end     = switches[index + 1]
                let running = UInt32(truncatingIfNeeded: start.b)

                guard end.ts > start.ts else { continue }

                let label = running == 0
                    ? "idle"
                    : (names[running].map { "\($0) (\(running))" } ?? "pid \(running)")

                events.append("""
                {"ph":"X","name":"\(Self.escaped(label))","cat":"schedule",\
                "ts":\(at(start.ts)),"dur":\(duration(end.ts - start.ts)),\
                "pid":\(Self.scheduleLane),"tid":\(Self.scheduleLane)}
                """)
            }

            events.append("""
            {"ph":"M","name":"process_name","pid":\(Self.scheduleLane),\
            "tid":\(Self.scheduleLane),"args":{"name":"CPU 0"}}
            """)
            events.append("""
            {"ph":"M","name":"thread_name","pid":\(Self.scheduleLane),\
            "tid":\(Self.scheduleLane),"args":{"name":"running"}}
            """)
        }


        /// A lane number no pid will collide with, and one the format can carry:
        /// process ids in a trace event file are signed 32-bit, so a lane past
        /// that is not a bigger number, it is a broken one.
        private static let scheduleLane: UInt64 = 0x7FFF_FFFF


        func finish() -> String {
            // `otherData` is where a viewer shows what it cannot draw. The clock
            // note is the important one: under QEMU's TCG the counter advances
            // with work rather than with wall time, so the shapes are honest and
            // the absolute durations are not.
            let other = """
            "otherData":{"counterFrequencyHz":"\(block.freq)",\
            "eventsLost":"\(block.lost)",\
            "kernelStackPeakBytes":"\(block.stack)",\
            "exceptionStackPeakBytes":"\(block.exceptionStack)",\
            "ringWindow":"the kernel ring holds the last 256 events; earlier ones were overwritten",\
            "clock":"CNTVCT_EL0; under QEMU TCG this advances with work, not wall time"}
            """

            return "{\"displayTimeUnit\":\"ms\",\(other),\"traceEvents\":[\n"
                + events.joined(separator: ",\n")
                + "\n]}\n"
        }
    }
}
