#!/usr/bin/env python3
#
# terminal-baseline-report.py
# ReixOS
#
# Turns one profiled 4 MiB terminal run into a baseline document. It accepts
# only the fixed records printed by Shell and the host trace decoder: unknown,
# conflicting, partial, and non-numeric records are evidence gaps, never zeros.

import json
import math
import os
import re
import subprocess
import sys


US_PER_SECOND = 1_000_000.0
UART_BAUD = 115_200.0
PAGE_BYTES = 4_096
LATENCIES = (
    "serial_delivery_to_decoded",
    "decoded_to_shell",
    "shell_to_editor",
    "editor_to_parser",
    "editor_to_presentation",
    "presentation_to_console_ack",
    "total",
)


class ReportError(Exception):
    pass


def fail(message):
    print(f"terminal-baseline-report: {message}", file=sys.stderr)
    raise ReportError(message)


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8") as source:
            return source.read().splitlines()
    except OSError as error:
        fail(f"cannot read {path}: {error}")


def parse_uint(value, field):
    if not re.fullmatch(r"[0-9]+", value):
        fail(f"non-numeric {field}: {value!r}")
    return int(value)


def last_trace_frequency(lines):
    open_block = None
    completed = []
    for line in lines:
        if line.startswith("[TRACE] begin "):
            fields = dict(token.split("=", 1) for token in line.split()[2:] if "=" in token)
            open_block = fields
        elif line.startswith("[TRACE] end") and open_block is not None:
            completed.append(open_block)
            open_block = None
    if not completed:
        fail("no complete trace block")
    frequency = parse_uint(completed[-1].get("freq", ""), "trace freq")
    if frequency <= 0:
        fail("last trace block has no positive frequency")
    return frequency


def parse_system(lines):
    prefix = "[ TERMINAL BASELINE ] system "
    measured = []
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = dict(token.split("=", 1) for token in line[len(prefix):].split() if "=" in token)
        if fields.get("status") == "measured":
            measured.append(fields)
    if not measured:
        fail("missing measured system baseline")
    fields = measured[-1]
    required = (
        "total_pages", "free_pages", "counter_freq", "trace_lost",
        "heap_high_water_bytes", "kernel_stack_peak_bytes", "exception_stack_peak_bytes",
    )
    return {name: parse_uint(fields.get(name, ""), f"system {name}") for name in required}


def parse_editor(lines, frequency):
    prefix = "[ TERMINAL BASELINE ] editor "
    wanted = {"paste-8192": None, "layout-8192": None}
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = dict(token.split("=", 1) for token in line[len(prefix):].split() if "=" in token)
        workload = fields.get("workload")
        if fields.get("status") != "measured" or workload not in wanted:
            continue
        cycles = parse_uint(fields.get("cycles", ""), f"editor {workload} cycles")
        measurement = {
            "bytes": parse_uint(fields.get("bytes", ""), f"editor {workload} bytes"),
            "cycles": cycles,
            "instructions": parse_uint(
                fields.get("instructions", ""), f"editor {workload} instructions"
            ),
            "microseconds": cycles * US_PER_SECOND / frequency,
        }
        if wanted[workload] is not None and wanted[workload] != measurement:
            fail(f"conflicting editor baseline for {workload}")
        wanted[workload] = measurement
    missing = [name for name, values in wanted.items() if values is None]
    if missing:
        fail(f"missing measured editor workloads: {', '.join(missing)}")
    if any(values["bytes"] != 8192 for values in wanted.values()):
        fail("editor workloads did not measure 8192 bytes")
    return wanted


def parse_processes(lines):
    prefix = "[ TERMINAL BASELINE ] process "
    wanted = {
        "SerialServer": None,
        "ConsoleServer": None,
        "InputServer": None,
        "VTAdapter": None,
        "Shell": None,
    }
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = dict(token.split("=", 1) for token in line[len(prefix):].split() if "=" in token)
        if fields.get("status") != "measured":
            continue
        name = fields.get("name")
        canonical = canonical_process_name(name)
        if canonical not in wanted:
            continue
        measurement = {
            "resident_pages": parse_uint(fields.get("resident_pages", ""), f"{canonical} resident_pages"),
            "stack_pages": parse_uint(fields.get("stack_pages", ""), f"{canonical} stack_pages"),
        }
        if wanted[canonical] is not None and wanted[canonical] != measurement:
            fail(f"conflicting process baseline for {canonical}")
        wanted[canonical] = measurement
    missing = [name for name, values in wanted.items() if values is None]
    if missing:
        fail(f"missing measured processes: {', '.join(missing)}")
    return wanted


def canonical_process_name(name):
    if not name:
        return None
    for canonical in ("SerialServer", "ConsoleServer", "InputServer", "VTAdapter", "Shell"):
        if not name.startswith(canonical):
            continue
        suffix = name[len(canonical):]
        if suffix == "" or suffix.startswith("."):
            return canonical
    return None


def parse_duration(value, frequency, field):
    if value == "unavailable":
        return None
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(us|ticks)", value)
    if not match:
        fail(f"non-numeric {field}: {value!r}")
    number = float(match.group(1))
    if not math.isfinite(number):
        fail(f"non-finite {field}")
    if match.group(2) == "ticks":
        return number * US_PER_SECOND / frequency
    return number


def parse_interactions(lines, frequency):
    header = None
    rows = []
    for line in lines:
        if line.startswith("interaction groups="):
            fields = dict(token.split("=", 1) for token in line.split() if "=" in token)
            header = fields
        elif line.startswith("interaction correlation="):
            fields = dict(token.split("=", 1) for token in line.split() if "=" in token)
            rows.append(fields)
    if header is None:
        fail("missing interaction header")
    groups = parse_uint(header.get("groups", ""), "interaction groups")
    invalid = parse_uint(header.get("invalid", ""), "interaction invalid")
    if groups <= 0 or invalid != 0:
        fail("interaction report requires groups>0 and invalid=0")
    if len(rows) != groups:
        fail("interaction group count does not match rows")

    latency_values = {name: [] for name in LATENCIES}
    rendered_bytes = []
    full_estimate_bytes = []
    diff_estimate_bytes = []
    render_plans = {"full": 0, "diff": 0}
    seen = set()
    for row in rows:
        correlation = parse_uint(row.get("correlation", ""), "interaction correlation")
        if correlation == 0 or correlation in seen:
            fail("invalid or duplicate interaction correlation")
        seen.add(correlation)
        if parse_uint(row.get("duplicate", ""), "interaction duplicate") != 0:
            fail(f"interaction {correlation} has duplicate points")
        for name in LATENCIES:
            value = parse_duration(row.get(name, ""), frequency, f"interaction {name}")
            if value is not None:
                latency_values[name].append(value)
        bytes_text = row.get("rendered_bytes", "")
        if bytes_text != "unavailable":
            rendered_bytes.append(parse_uint(bytes_text, "rendered_bytes"))
        full_text = row.get("full_estimate_bytes", "")
        if full_text != "unavailable":
            full_estimate_bytes.append(parse_uint(full_text, "full_estimate_bytes"))
        diff_text = row.get("diff_estimate_bytes", "")
        if diff_text != "unavailable":
            diff_estimate_bytes.append(parse_uint(diff_text, "diff_estimate_bytes"))
        plan = row.get("render_plan", "")
        if plan in render_plans:
            render_plans[plan] += 1
        elif plan != "unavailable":
            fail("unknown render plan")
    if not any(latency_values.values()):
        fail("no latency metric is available")
    if not latency_values["total"]:
        fail("no total interaction samples are available")
    return (
        groups,
        invalid,
        latency_values,
        rendered_bytes,
        full_estimate_bytes,
        diff_estimate_bytes,
        render_plans,
    )


def nearest_rank(samples, percentile):
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def latency_metric(samples, unit="microseconds"):
    if not samples:
        return {"status": "unavailable", "reason": "no-complete-samples"}
    suffix = "bytes" if unit == "bytes" else "us"
    return {
        "status": "measured",
        "samples": len(samples),
        f"p50_{suffix}": nearest_rank(samples, 0.50),
        f"p95_{suffix}": nearest_rank(samples, 0.95),
        "unit": unit,
        "provenance": "kernel-counter",
    }


def git_provenance():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    try:
        revision = subprocess.check_output(
            ["git", "-C", root, "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
        dirty = subprocess.run(
            ["git", "-C", root, "diff", "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode != 0
        return revision, dirty
    except (OSError, subprocess.SubprocessError):
        return "unavailable", False


def main(arguments):
    if len(arguments) != 3:
        print("usage: terminal-baseline-report.py SERIAL_LOG INTERACTION_REPORT OUTPUT_JSON", file=sys.stderr)
        return 1
    serial_path, interaction_path, output_path = arguments
    try:
        serial_lines = read_lines(serial_path)
        interaction_lines = read_lines(interaction_path)
        frequency = last_trace_frequency(serial_lines)
        system = parse_system(serial_lines)
        if system["trace_lost"] != 0:
            fail("terminal workload lost trace events")
        processes = parse_processes(serial_lines)
        editor = parse_editor(serial_lines, frequency)
        (
            groups,
            invalid,
            latency_values,
            rendered_bytes,
            full_estimate_bytes,
            diff_estimate_bytes,
            render_plans,
        ) = parse_interactions(interaction_lines, frequency)
        revision, dirty = git_provenance()

        latencies = {name: latency_metric(latency_values[name]) for name in LATENCIES}
        rendered = latency_metric([float(value) for value in rendered_bytes], unit="bytes")
        if rendered["status"] == "measured":
            rendered["provenance"] = "console-acknowledged-rendered-byte-count"
        wire = latency_metric([value * 10.0 * US_PER_SECOND / UART_BAUD for value in rendered_bytes])
        if wire["status"] == "measured":
            wire["status"] = "derived"
            wire["provenance"] = "estimated-115200-8n1-frame-time"
        full_estimate = latency_metric([float(value) for value in full_estimate_bytes], unit="bytes")
        diff_estimate = latency_metric([float(value) for value in diff_estimate_bytes], unit="bytes")
        for metric in [full_estimate, diff_estimate]:
            if metric["status"] == "measured":
                metric["provenance"] = "vt-deterministic-encoded-byte-count"

        document = {
            "build_mode": "REIX_TERMINAL_PROFILE",
            "guest_memory_bytes": 4_194_304,
            "initrd": "embedded",
            "interactions": {
                "complete_total_samples": len(latency_values["total"]),
                "groups": groups,
                "invalid": invalid,
                "latencies": latencies,
                "rendered_bytes": rendered,
                "render_plan": {
                    "full_count": render_plans["full"],
                    "diff_count": render_plans["diff"],
                    "full_estimate_bytes": full_estimate,
                    "diff_estimate_bytes": diff_estimate,
                },
                "wire_time_us": wire,
            },
            "note": (
                "latencies include interaction-mark syscall overhead; "
                "serial_delivery_to_decoded starts at VTAdapter delivery, and "
                "wire_time_us is an estimated 115200 8N1 frame time"
            ),
            "processes": {
                name: {
                    "resident_pages": {"status": "measured", "value": values["resident_pages"], "provenance": "serial"},
                    "stack_pages": {"status": "measured", "value": values["stack_pages"], "provenance": "serial"},
                }
                for name, values in processes.items()
            },
            "editor_workloads": {
                name: {
                    "bytes": {"status": "measured", "value": values["bytes"], "provenance": "serial"},
                    "cycles": {"status": "measured", "value": values["cycles"], "provenance": "pmu-el0"},
                    "instructions": {
                        "status": "measured", "value": values["instructions"], "provenance": "pmu-el0"
                    },
                    "microseconds": {
                        "status": "derived", "value": values["microseconds"],
                        "provenance": "pmu-cycles-over-counter-frequency"
                    },
                }
                for name, values in editor.items()
            },
            "provenance": {
                "dirty": dirty,
                "git_revision": revision,
                "qemu_version": os.environ.get("QEMU_VERSION", "unavailable"),
                "sources": {"interaction_report": interaction_path, "serial_log": serial_path},
            },
            "schema_version": 1,
            "system": {
                "counter_freq": {"status": "measured", "value": system["counter_freq"], "provenance": "serial"},
                "exception_stack_peak_bytes": {"status": "measured", "value": system["exception_stack_peak_bytes"], "provenance": "serial"},
                "free_bytes": {"status": "derived", "value": system["free_pages"] * PAGE_BYTES, "provenance": "pages-4096"},
                "free_pages": {"status": "measured", "value": system["free_pages"], "provenance": "serial"},
                "heap_high_water_bytes": {
                    "status": "measured", "value": system["heap_high_water_bytes"], "provenance": "serial"
                },
                "kernel_stack_peak_bytes": {"status": "measured", "value": system["kernel_stack_peak_bytes"], "provenance": "serial"},
                "total_pages": {"status": "measured", "value": system["total_pages"], "provenance": "serial"},
                "trace_lost": {"status": "measured", "value": system["trace_lost"], "provenance": "serial"},
                "trace_overflow_during_workload": {
                    "status": "measured",
                    "value": system["trace_lost"],
                    "provenance": "trace-reset-before-workload",
                },
            },
            "workload": {
                "command": "shell.exit()",
                "editor": ["paste-8192", "layout-8192"],
                "storage": "absent",
            },
        }
        with open(output_path, "w", encoding="utf-8", newline="\n") as output:
            json.dump(document, output, sort_keys=True, separators=(",", ":"), allow_nan=False)
            output.write("\n")
    except ReportError:
        return 1
    except (OSError, ValueError, TypeError) as error:
        print(f"terminal-baseline-report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
