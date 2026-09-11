#!/usr/bin/env python3
#
# terminal-baseline-report.py
# ReixOS
#
# Turns one profiled terminal run into a baseline document. It accepts
# only the fixed records printed by Shell and the host trace decoder: unknown,
# conflicting, partial, and non-numeric records are evidence gaps, never zeros.

import json
import hashlib
import math
import os
import re
import shlex
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


def parse_fields(tokens, context):
    fields = {}
    for token in tokens:
        if "=" not in token:
            continue
        name, value = token.split("=", 1)
        if name in fields:
            fail(f"duplicate {context} field: {name}")
        fields[name] = value
    # The records carry no version tag: there is one of each. A line that still
    # has one was printed by an image this reporter does not know.
    if "schema" in fields:
        fail(f"{context} record carries an unknown schema tag")
    return fields


def last_cli_option(tokens, name):
    value = None
    for index, token in enumerate(tokens):
        if token == name:
            if index + 1 >= len(tokens):
                fail(f"manifest QEMU option has no value: {name}")
            value = tokens[index + 1]
        elif token.startswith(name + "="):
            value = token[len(name) + 1:]
    return value


def last_trace_header(lines):
    open_block = None
    completed = []
    event_count = 0
    saw_drop = False
    for line in lines:
        if line.startswith("[TRACE] begin "):
            if open_block is not None:
                fail("nested or truncated trace block")
            fields = parse_fields(line.split()[2:], "trace header")
            open_block = fields
            event_count = 0
            saw_drop = False
        elif line.startswith("[TRACE] t="):
            if open_block is not None:
                event_count += 1
        elif line.startswith("[TRACE-DROP]"):
            if open_block is not None:
                saw_drop = True
        elif line.startswith("[TRACE] end"):
            if open_block is None:
                fail("trace end without begin")
            end_fields = parse_fields(line.split()[2:], "trace trailer")
            declared_count = parse_uint(end_fields.get("count", ""), "trace count")
            if declared_count != event_count:
                fail("trace trailer count disagrees with emitted records")
            completed.append((open_block, saw_drop))
            open_block = None
    if open_block is not None:
        fail("truncated final trace block")
    if not completed:
        fail("no complete trace block")
    header, final_saw_drop = completed[-1]
    if final_saw_drop:
        fail("final trace block contains a transmit drop")
    if parse_uint(header.get("v", ""), "trace schema") != 2:
        fail("unsupported trace schema")
    frequency = parse_uint(header.get("freq", ""), "trace freq")
    lost = parse_uint(header.get("lost", ""), "trace lost")
    if frequency <= 0:
        fail("last trace block has no positive frequency")
    return frequency, lost


def parse_system(lines):
    prefix = "[ TERMINAL BASELINE ] system "
    records = []
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = parse_fields(line[len(prefix):].split(), "system")
        records.append(fields)
    if len(records) != 1 or records[0].get("status") != "measured":
        fail("system baseline must contain exactly one measured record")
    fields = records[0]
    required = (
        "page_bytes", "physical_total_pages", "physical_allocated_pages",
        "physical_free_pages", "kernel_heap_live_capacity_bytes",
        "kernel_heap_live_high_water_bytes", "kernel_heap_reserved_bytes",
        "kernel_heap_reserved_high_water_bytes", "timer_frequency_hz", "trace_lost",
        "kernel_stack_used_high_water_bytes", "kernel_stack_capacity_bytes",
        "exception_stack_used_high_water_bytes", "exception_stack_capacity_bytes",
    )
    values = {name: parse_uint(fields.get(name, ""), f"system {name}") for name in required}
    if values["page_bytes"] != PAGE_BYTES:
        fail("unsupported system metric page size")
    if values["physical_allocated_pages"] > values["physical_total_pages"]:
        fail("physical allocated pages exceed total pages")
    if values["physical_free_pages"] != values["physical_total_pages"] - values["physical_allocated_pages"]:
        fail("physical page accounting does not balance")
    if values["kernel_heap_live_capacity_bytes"] > values["kernel_heap_reserved_bytes"]:
        fail("kernel heap live capacity exceeds reserved backing")
    if values["kernel_heap_live_capacity_bytes"] > values["kernel_heap_live_high_water_bytes"]:
        fail("kernel heap live capacity exceeds its high-water mark")
    if values["kernel_heap_reserved_bytes"] > values["kernel_heap_reserved_high_water_bytes"]:
        fail("kernel heap reserved backing exceeds its high-water mark")
    if values["kernel_stack_used_high_water_bytes"] > values["kernel_stack_capacity_bytes"]:
        fail("kernel stack use exceeds capacity")
    if values["exception_stack_used_high_water_bytes"] > values["exception_stack_capacity_bytes"]:
        fail("exception stack use exceeds capacity")

    pmu_status = fields.get("pmu_status")
    if pmu_status == "available":
        values["pmu_event_counters"] = parse_uint(
            fields.get("pmu_event_counters", ""), "system pmu_event_counters"
        )
        if "pmu_reason" in fields:
            fail("available PMU must not have an unavailability reason")
        instruction_status = fields.get("instruction_event_status")
        if instruction_status not in ("available", "unavailable"):
            fail("available PMU needs instruction-event availability")
        if instruction_status == "available" and values["pmu_event_counters"] <= 0:
            fail("instruction event cannot be available without an event counter")
        if instruction_status == "available":
            if "instruction_reason" in fields:
                fail("available instruction event must not have an unavailability reason")
        elif not fields.get("instruction_reason"):
            fail("unavailable instruction event needs a reason")
        values["instruction_event_status"] = instruction_status
        if instruction_status == "unavailable":
            values["instruction_reason"] = fields["instruction_reason"]
    elif pmu_status == "unavailable":
        if not fields.get("pmu_reason") or "pmu_event_counters" in fields:
            fail("unavailable PMU needs a reason and no counter value")
        values["pmu_reason"] = fields["pmu_reason"]
    else:
        fail("missing or unsupported PMU status")
    values["pmu_status"] = pmu_status
    return values


def parse_user_heap(lines):
    prefix = "[ TERMINAL BASELINE ] user_heap "
    records = []
    for line in lines:
        if line.startswith(prefix):
            fields = parse_fields(line[len(prefix):].split(), "user_heap")
            records.append(fields)
    if len(records) != 1 or records[0].get("status") != "measured":
        fail("user heap baseline must contain exactly one measured record")
    fields = records[0]
    if fields.get("domain") != "virtual-reservation" \
            or fields.get("unit") != "bytes" or not fields.get("process"):
        fail("unsupported user heap metric domain")
    reserved = parse_uint(fields.get("reserved_bytes", ""), "user heap reserved_bytes")
    high_water = parse_uint(fields.get("high_water_bytes", ""), "user heap high_water_bytes")
    if reserved > high_water:
        fail("user heap reservation exceeds its high-water mark")
    return {"process": fields["process"], "reserved_bytes": reserved, "high_water_bytes": high_water}


def parse_editor(lines, pmu_status, instruction_event_status):
    prefix = "[ TERMINAL BASELINE ] editor "
    wanted = {"paste-8192": None, "layout-8192": None}
    for line in lines:
        if not line.startswith(prefix):
            continue
        fields = parse_fields(line[len(prefix):].split(), "editor")
        workload = fields.get("workload")
        if workload not in wanted:
            continue
        if fields.get("status") != "measured" or fields.get("timer_unit") != "ticks":
            fail(f"editor {workload} has unsupported timer unit or status")
        byte_count = parse_uint(fields.get("bytes", ""), f"editor {workload} bytes")
        timer_ticks = parse_uint(fields.get("timer_ticks", ""), f"editor {workload} timer_ticks")
        if fields.get("pmu_status") == "available":
            if pmu_status != "available" or fields.get("counter_unit") != "raw" \
                    or "reason" in fields:
                fail(f"editor {workload} measured counters without available raw PMU")
            measurement = {
                "pmu_status": "available", "bytes": byte_count, "timer_ticks": timer_ticks,
                "cycles": parse_uint(fields.get("cycles", ""), f"editor {workload} cycles"),
            }
            instruction_status = fields.get("instruction_event_status")
            if instruction_status == "available":
                if "instruction_reason" in fields:
                    fail(f"editor {workload} has an instruction value and reason")
                measurement["instructions"] = parse_uint(
                    fields.get("instructions", ""), f"editor {workload} instructions"
                )
            elif instruction_status == "unavailable":
                if not fields.get("instruction_reason") or "instructions" in fields:
                    fail(f"editor {workload} has malformed unavailable instruction event")
                measurement["instruction_reason"] = fields["instruction_reason"]
            else:
                fail(f"editor {workload} has unsupported instruction-event status")
            if instruction_status != instruction_event_status:
                fail(f"editor {workload} instruction-event availability disagrees with system")
            measurement["instruction_event_status"] = instruction_status
        elif fields.get("pmu_status") == "unavailable":
            if pmu_status != "unavailable" or not fields.get("reason") \
                    or "cycles" in fields or "instructions" in fields:
                fail(f"editor {workload} has malformed unavailable counters")
            measurement = {
                "pmu_status": "unavailable", "bytes": byte_count,
                "timer_ticks": timer_ticks, "reason": fields["reason"]
            }
        else:
            fail(f"editor {workload} has unsupported PMU status")
        if wanted[workload] is not None:
            fail(f"duplicate editor baseline for {workload}")
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
        fields = parse_fields(line[len(prefix):].split(), "process")
        name = fields.get("name")
        canonical = canonical_process_name(name)
        if canonical not in wanted:
            continue
        if fields.get("status") != "measured":
            fail(f"process metrics unavailable for {canonical}")
        measurement = {
            "mapped_pages": parse_uint(fields.get("mapped_pages", ""), f"{canonical} mapped_pages"),
            "virtual_extent_pages": parse_uint(fields.get("virtual_extent_pages", ""), f"{canonical} virtual_extent_pages"),
            "stack_extent_pages": parse_uint(fields.get("stack_extent_pages", ""), f"{canonical} stack_extent_pages"),
            "stack_capacity_pages": parse_uint(fields.get("stack_capacity_pages", ""), f"{canonical} stack_capacity_pages"),
        }
        if fields.get("mapped_semantics") != "address-space-nonunique":
            fail(f"unsupported mapped-page semantics for {canonical}")
        if measurement["mapped_pages"] > measurement["virtual_extent_pages"]:
            fail(f"{canonical} mapped pages exceed virtual extent")
        if measurement["stack_extent_pages"] > measurement["stack_capacity_pages"]:
            fail(f"{canonical} stack accounting does not nest")
        if wanted[canonical] is not None:
            fail(f"duplicate process baseline for {canonical}")
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
            if header is not None:
                fail("duplicate interaction header")
            fields = parse_fields(line.split(), "interaction header")
            header = fields
        elif line.startswith("interaction correlation="):
            fields = parse_fields(line.split(), "interaction row")
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


def load_manifest(path):
    try:
        with open(path, "r", encoding="utf-8") as source:
            manifest = json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read run manifest {path}: {error}")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        fail("unsupported run manifest schema")
    required = {
        "build_mode": str,
        "guest_memory_bytes": int,
        "initrd": str,
        "pmu": str,
        "storage": str,
        "pre_shell_workload": str,
        "workload_id": str,
        "command": str,
        "kernel_sha256": str,
        "disk_sha256": str,
        "input_sha256": str,
        "toolchain": str,
        "measurement_scope": str,
        "trace_scope": str,
        "qemu_flags": str,
        "working_directory": str,
        "effective_cpu": str,
        "effective_drive_file": str,
        "machine": str,
        "vcpu_count": int,
        "initrd_artifact": dict,
        "disk_hash_scope": str,
        "kernel_path": str,
        "disk_path": str,
    }
    for name, expected in required.items():
        value = manifest.get(name)
        if not isinstance(value, expected) or (expected is str and not value):
            fail(f"missing or malformed run manifest field: {name}")
    if manifest["build_mode"] != "instrumented":
        fail("terminal metric report requires an instrumented build")
    if manifest["measurement_scope"] != "terminal-interactions-and-final-snapshot":
        fail("manifest measurement scope does not match the terminal report")
    if manifest["trace_scope"] != "bounded-ring-cumulative-at-final-dump":
        fail("manifest trace scope does not match the terminal report")
    if manifest["pre_shell_workload"] != "StorageCheck":
        fail("terminal workload requires StorageCheck in the same guest execution")
    if manifest["vcpu_count"] != 1:
        fail("terminal metric report requires one vCPU")
    if manifest["disk_hash_scope"] != "pre-run":
        fail("terminal metric report requires a pre-run disk hash")
    qemu_tokens = shlex.split(manifest["qemu_flags"])
    if last_cli_option(qemu_tokens, "-cpu") != manifest["effective_cpu"] \
            or last_cli_option(qemu_tokens, "-machine") != manifest["machine"]:
        fail("effective QEMU CPU or machine disagrees with final flags")
    pmu_match = re.search(r"(?:^|,)pmu=(on|off)(?:,|$)", manifest["effective_cpu"])
    if not pmu_match or pmu_match.group(1) != manifest["pmu"]:
        fail("effective QEMU CPU disagrees with manifest PMU mode")
    smp = last_cli_option(qemu_tokens, "-smp")
    effective_vcpus = int(smp.split(",", 1)[0]) if smp else 1
    if effective_vcpus != manifest["vcpu_count"]:
        fail("effective QEMU vCPU count disagrees with manifest")
    drive = last_cli_option(qemu_tokens, "-drive")
    device = last_cli_option(qemu_tokens, "-device")
    drive_fields = dict(
        field.split("=", 1) for field in (drive or "").split(",") if "=" in field
    )
    if drive_fields.get("id") != "reixdisk" \
            or drive_fields.get("file") != manifest["effective_drive_file"] \
            or device != "virtio-blk-device,drive=reixdisk":
        fail("effective QEMU block device disagrees with manifest")
    effective_disk = os.path.abspath(os.path.join(
        manifest["working_directory"], manifest["effective_drive_file"]
    ))
    if effective_disk != manifest["disk_path"]:
        fail("hashed disk path is not the image QEMU mounts")
    if not os.path.isabs(manifest["kernel_path"]):
        fail("manifest kernel path is not absolute")
    initrd = manifest["initrd_artifact"]
    if initrd.get("mode") not in ("embedded-in-kernel", "qemu-file") \
            or not re.fullmatch(r"[0-9a-f]{64}", initrd.get("sha256", "")):
        fail("run manifest initrd artifact is malformed")
    if manifest["initrd"] == "embedded":
        if initrd.get("mode") != "embedded-in-kernel" \
                or initrd.get("hash_scope") != "kernel-image-includes-initrd" \
                or initrd["sha256"] != manifest["kernel_sha256"]:
            fail("embedded initrd is not bound to the kernel image")
    elif initrd.get("mode") != "qemu-file":
        fail("qemu initrd mode needs a separately hashed artifact")
    if manifest["guest_memory_bytes"] <= 0 or manifest["initrd"] not in ("embedded", "qemu"):
        fail("unsupported manifest memory or initrd mode")
    if manifest["pmu"] not in ("on", "off") \
            or manifest["storage"] != "virtio-blk-rxfs-storagecheck-shell":
        fail("baseline workload requires explicit PMU mode and attached storage")
    if "virtio-blk-device" not in manifest["qemu_flags"]:
        fail("manifest storage workload has no virtio block device")
    for name in ("kernel_sha256", "disk_sha256", "input_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", manifest[name]):
            fail(f"run manifest {name} is not SHA-256")
    if hashlib.sha256(manifest["command"].encode("utf-8")).hexdigest() \
            != manifest["input_sha256"]:
        fail("run manifest input hash disagrees with decoded command")
    return manifest


def main(arguments):
    if len(arguments) != 4:
        print("usage: terminal-baseline-report.py SERIAL_LOG INTERACTION_REPORT RUN_MANIFEST OUTPUT_JSON", file=sys.stderr)
        return 1
    serial_path, interaction_path, manifest_path, output_path = arguments
    try:
        manifest = load_manifest(manifest_path)
        serial_lines = read_lines(serial_path)
        interaction_lines = read_lines(interaction_path)
        frequency, dumped_lost = last_trace_header(serial_lines)
        system = parse_system(serial_lines)
        user_heap = parse_user_heap(serial_lines)
        if frequency != system["timer_frequency_hz"]:
            fail("trace frequency disagrees with system generic timer")
        if dumped_lost != system["trace_lost"]:
            fail("final trace dump loss disagrees with the system snapshot")
        if dumped_lost != 0:
            fail("terminal workload lost trace events")
        processes = parse_processes(serial_lines)
        editor = parse_editor(
            serial_lines,
            system["pmu_status"],
            system.get("instruction_event_status", "unavailable"),
        )
        if (manifest["pmu"] == "on") != (system["pmu_status"] == "available"):
            fail("manifest PMU mode disagrees with guest availability")
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
            "build_mode": manifest["build_mode"],
            "guest_memory_bytes": manifest["guest_memory_bytes"],
            "initrd": manifest["initrd"],
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
                    "mapped_pages": {"status": "measured", "value": values["mapped_pages"], "provenance": "address-space-nonunique"},
                    "virtual_extent_pages": {"status": "measured", "value": values["virtual_extent_pages"], "provenance": "vma-extent"},
                    "stack_extent_pages": {"status": "measured", "value": values["stack_extent_pages"], "provenance": "grow-down-vma-high-water"},
                    "stack_capacity_pages": {"status": "measured", "value": values["stack_capacity_pages"], "provenance": "vma-gap-limit"},
                }
                for name, values in processes.items()
            },
            "editor_workloads": {
                name: ({
                    "bytes": {"status": "measured", "value": values["bytes"], "provenance": "serial"},
                    "duration_ticks": {"status": "measured", "value": values["timer_ticks"], "unit": "generic-timer-ticks", "provenance": "cntvct-el0"},
                    "duration_us": {"status": "derived", "value": values["timer_ticks"] * US_PER_SECOND / system["timer_frequency_hz"], "unit": "microseconds", "provenance": "generic-timer"},
                    "cycles": {"status": "measured", "value": values["cycles"], "unit": "raw-pmu-cycles", "provenance": "pmu-el0"},
                    "instructions": (
                        {"status": "measured", "value": values["instructions"], "unit": "raw-event0", "provenance": "pmu-el0"}
                        if values["instruction_event_status"] == "available" else
                        {"status": "unavailable", "reason": values["instruction_reason"]}
                    ),
                } if values["pmu_status"] == "available" else {
                    "bytes": {"status": "measured", "value": values["bytes"], "provenance": "serial"},
                    "duration_ticks": {"status": "measured", "value": values["timer_ticks"], "unit": "generic-timer-ticks", "provenance": "cntvct-el0"},
                    "duration_us": {"status": "derived", "value": values["timer_ticks"] * US_PER_SECOND / system["timer_frequency_hz"], "unit": "microseconds", "provenance": "generic-timer"},
                    "cycles": {"status": "unavailable", "reason": values["reason"]},
                    "instructions": {"status": "unavailable", "reason": values["reason"]},
                })
                for name, values in editor.items()
            },
            "provenance": {
                "dirty": dirty,
                "git_revision": revision,
                "qemu_version": os.environ.get("QEMU_VERSION", "unavailable"),
                "sources": {"interaction_report": interaction_path, "serial_log": serial_path},
                "run_manifest": manifest_path,
                "binary_and_input": {
                    "kernel_sha256": manifest["kernel_sha256"],
                    "disk_sha256": manifest["disk_sha256"],
                    "input_sha256": manifest["input_sha256"],
                    "toolchain": manifest["toolchain"],
                    "qemu_flags": manifest["qemu_flags"],
                    "working_directory": manifest["working_directory"],
                    "effective_cpu": manifest["effective_cpu"],
                    "effective_drive_file": manifest["effective_drive_file"],
                    "machine": manifest["machine"],
                    "vcpu_count": manifest["vcpu_count"],
                    "initrd_artifact": manifest["initrd_artifact"],
                    "disk_hash_scope": manifest["disk_hash_scope"],
                    "kernel_path": manifest["kernel_path"],
                    "disk_path": manifest["disk_path"],
                },
            },
            "schema_version": 2,
            "system": {
                "page_bytes": PAGE_BYTES,
                "physical_total_pages": {"status": "measured", "value": system["physical_total_pages"], "provenance": "ppm"},
                "physical_allocated_pages": {"status": "measured", "value": system["physical_allocated_pages"], "provenance": "ppm"},
                "physical_free_pages": {"status": "measured", "value": system["physical_free_pages"], "provenance": "ppm"},
                "kernel_heap_live_capacity_bytes": {"status": "measured", "value": system["kernel_heap_live_capacity_bytes"], "provenance": "kernel-heap-rounded-capacity"},
                "kernel_heap_live_high_water_bytes": {"status": "measured", "value": system["kernel_heap_live_high_water_bytes"], "provenance": "kernel-heap-rounded-capacity"},
                "kernel_heap_reserved_bytes": {"status": "measured", "value": system["kernel_heap_reserved_bytes"], "provenance": "kernel-heap-physical-backing"},
                "kernel_heap_reserved_high_water_bytes": {"status": "measured", "value": system["kernel_heap_reserved_high_water_bytes"], "provenance": "kernel-heap-physical-backing"},
                "timer_frequency_hz": {"status": "measured", "value": system["timer_frequency_hz"], "provenance": "generic-timer"},
                "user_heap_virtual_reservation_bytes": {"status": "measured", "value": user_heap["reserved_bytes"], "provenance": "shell-user-heap"},
                "user_heap_virtual_high_water_bytes": {"status": "measured", "value": user_heap["high_water_bytes"], "provenance": "shell-user-heap"},
                "kernel_stack_used_high_water_bytes": {"status": "measured", "value": system["kernel_stack_used_high_water_bytes"], "provenance": "stack-poison-scan"},
                "kernel_stack_capacity_bytes": {"status": "measured", "value": system["kernel_stack_capacity_bytes"], "provenance": "linker-span"},
                "exception_stack_used_high_water_bytes": {"status": "measured", "value": system["exception_stack_used_high_water_bytes"], "provenance": "panic-only-stack-poison-scan"},
                "exception_stack_capacity_bytes": {"status": "measured", "value": system["exception_stack_capacity_bytes"], "provenance": "linker-span"},
                "pmu": ({"status": "available", "event_counters": system["pmu_event_counters"],
                         "instructions_retired": (
                             {"status": "available", "provenance": "pmceid0-event-0x08"}
                             if system["instruction_event_status"] == "available" else
                             {"status": "unavailable", "reason": system["instruction_reason"],
                              "provenance": "pmceid0-event-0x08"}
                         ),
                         "provenance": "kernel-pmu-probe"}
                        if system["pmu_status"] == "available" else
                        {"status": "unavailable", "reason": system["pmu_reason"], "provenance": "kernel-pmu-probe"}),
                "trace_lost": {"status": "measured", "value": system["trace_lost"], "provenance": "serial"},
                "trace_lost_final_snapshot": {
                    "status": "measured",
                    "value": system["trace_lost"],
                    "scope": manifest["trace_scope"],
                    "provenance": "trace-ring-final-dump",
                },
            },
            "workload": {
                "id": manifest["workload_id"],
                "command": manifest["command"],
                "editor": ["paste-8192", "layout-8192"],
                "storage": manifest["storage"],
                "pre_shell_workload": manifest["pre_shell_workload"],
                "pmu": manifest["pmu"],
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
