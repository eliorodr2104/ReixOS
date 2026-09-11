#!/usr/bin/env python3
"""Write the immutable inputs of one reproducible guest workload."""

import argparse
import codecs
import hashlib
import json
import re
import shlex
from pathlib import Path


def memory_bytes(value: str) -> int:
    suffixes = {"K": 1024, "M": 1024**2, "G": 1024**3}
    if value[-1:].upper() in suffixes:
        return int(value[:-1]) * suffixes[value[-1].upper()]
    return int(value)


def digest(path: str) -> str:
    sha = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(chunk)
    return sha.hexdigest()


def last_option(tokens: list[str], name: str) -> str | None:
    value = None
    for index, token in enumerate(tokens):
        if token == name:
            if index + 1 >= len(tokens):
                raise ValueError(f"{name} has no value")
            value = tokens[index + 1]
        elif token.startswith(name + "="):
            value = token[len(name) + 1:]
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--build-mode", choices=("normal", "instrumented"), required=True)
    parser.add_argument("--memory", required=True)
    parser.add_argument("--initrd", choices=("embedded", "qemu"), required=True)
    parser.add_argument("--pmu", choices=("on", "off"), required=True)
    parser.add_argument("--storage", required=True)
    parser.add_argument("--pre-shell-workload", required=True)
    parser.add_argument("--workload-id", required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--disk", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--qemu-flags", required=True)
    parser.add_argument("--initrd-path")
    args = parser.parse_args()

    # Matches the \n/\033 notation consumed by smoke.sh's `printf %b` for the
    # scenario vocabulary. The stored command and its digest describe bytes the
    # guest actually receives, rather than the TSV escape spelling.
    command_bytes = codecs.decode(args.command, "unicode_escape").encode("latin1")
    qemu_tokens = shlex.split(args.qemu_flags)
    effective_cpu = last_option(qemu_tokens, "-cpu")
    machine = last_option(qemu_tokens, "-machine")
    if not effective_cpu or not machine:
        raise ValueError("QEMU flags require explicit -machine and -cpu")
    pmu_match = re.search(r"(?:^|,)pmu=(on|off)(?:,|$)", effective_cpu)
    if not pmu_match or pmu_match.group(1) != args.pmu:
        raise ValueError("manifest PMU mode disagrees with the effective final -cpu")
    smp = last_option(qemu_tokens, "-smp")
    vcpu_count = int(smp.split(",", 1)[0]) if smp else 1
    if vcpu_count != 1:
        raise ValueError("T07 workloads require exactly one vCPU")
    drive = last_option(qemu_tokens, "-drive")
    device = last_option(qemu_tokens, "-device")
    drive_fields = dict(
        field.split("=", 1) for field in (drive or "").split(",") if "=" in field
    )
    if drive_fields.get("id") != "reixdisk" or not drive_fields.get("file") \
            or Path(drive_fields["file"]).resolve() != Path(args.disk).resolve():
        raise ValueError("manifest disk is not the reixdisk image QEMU mounts")
    if device != "virtio-blk-device,drive=reixdisk":
        raise ValueError("QEMU flags do not bind virtio-blk-device to reixdisk")

    kernel_hash = digest(args.kernel)
    if args.initrd == "qemu":
        if not args.initrd_path:
            raise ValueError("qemu initrd mode requires --initrd-path")
        initrd_artifact = {
            "mode": "qemu-file",
            "sha256": digest(args.initrd_path),
        }
    else:
        initrd_artifact = {
            "mode": "embedded-in-kernel",
            "sha256": kernel_hash,
            "hash_scope": "kernel-image-includes-initrd",
        }

    document = {
        "schema_version": 1,
        "build_mode": args.build_mode,
        "guest_memory_bytes": memory_bytes(args.memory),
        "initrd": args.initrd,
        "pmu": args.pmu,
        "storage": args.storage,
        "pre_shell_workload": args.pre_shell_workload,
        "workload_id": args.workload_id,
        "command": command_bytes.decode("utf-8"),
        "measurement_scope": (
            "terminal-interactions-and-final-snapshot"
            if args.build_mode == "instrumented"
            else "complete-workload-verdict"
        ),
        "trace_scope": "bounded-ring-cumulative-at-final-dump",
        "qemu_flags": args.qemu_flags,
        "working_directory": str(Path.cwd()),
        "effective_cpu": effective_cpu,
        "effective_drive_file": drive_fields["file"],
        "machine": machine,
        "vcpu_count": vcpu_count,
        "initrd_artifact": initrd_artifact,
        "kernel_sha256": kernel_hash,
        "kernel_path": str(Path(args.kernel).resolve()),
        "disk_sha256": digest(args.disk),
        "disk_path": str(Path(args.disk).resolve()),
        "disk_hash_scope": "pre-run",
        "input_sha256": hashlib.sha256(command_bytes).hexdigest(),
        "toolchain": args.toolchain,
    }
    Path(args.output).write_text(
        json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
