#!/usr/bin/env python3
"""Build and run the AArch64 FP/SIMD context-switch guest oracle.

The active checkout is never built or rewritten. The runner snapshots tracked
and untracked, non-ignored files into a temporary directory, builds there, and
keeps the complete workspace and logs as evidence.

By default it runs the real oracle, two negative controls, the emergency panic
path, and a deterministic two-process switching benchmark:

* restore: corrupt Q8.high after exception return; the EL0 oracle must detect it.
* canonical: omit the handler FPCR/FPSR reset; the EL1 oracle must panic.
* guard: fault with less than one trap frame left on the kernel stack; the
  complete panic report must finish from the exception stack.
* benchmark: measure 21 batches of 10,000 round trips through a yield-only peer
  with QEMU icount. These are virtual instruction costs, not hardware timings.

Tool paths may be overridden with REIX_SWIFT, REIX_CLANG, REIX_LLVM_AR, and
REIX_QEMU. No override is tied to a developer's home directory.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time


TRIPLE = "aarch64-none-none-elf"
MODES = ("normal", "restore", "canonical", "guard", "benchmark")


def tool(environment: str, fallback: str) -> str:
    candidate = os.environ.get(environment, fallback)
    resolved = shutil.which(candidate)
    if resolved is None:
        raise RuntimeError(f"{candidate!r} was not found; set {environment}")
    return resolved


def snapshot(source: Path, target: Path, git: str) -> None:
    names = subprocess.check_output(
        [git, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=source,
    ).decode().split("\0")

    for name in names:
        if not name:
            continue
        source_file = source / name
        if not source_file.is_file():
            continue
        target_file = target / name
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file, follow_symlinks=False)


def run_logged(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    log: Path,
) -> None:
    with log.open("wb") as output:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
        )
    if result.returncode != 0:
        tail = log.read_text(errors="replace").splitlines()[-30:]
        raise RuntimeError(
            f"{' '.join(command)} failed ({result.returncode}); "
            f"see {log}\n" + "\n".join(tail)
        )


def mutate_context_saving(source: str, mode: str) -> str:
    if mode in ("normal", "guard", "benchmark"):
        return source

    if mode == "restore":
        needle = "    ldp     q8, q9,    [sp, #416]\n"
        if source.count(needle) != 1:
            raise RuntimeError("restore mutation no longer identifies one Q8 reload")
        return source.replace(
            needle,
            needle
            + "    ldr     x2, [sp, #256]\n"
            + "    and     x2, x2, #0xF\n"
            + "    cbnz    x2, 97f\n"
            + "    ins     v8.d[1], xzr // FP/SIMD oracle mutation\n"
            + "97:\n",
        )

    marker = "// Every Swift handler starts from one deterministic FP environment."
    marker_index = source.find(marker)
    if marker_index < 0:
        raise RuntimeError("canonical mutation marker is missing")

    reset = "    msr     fpcr, xzr\n    msr     fpsr, xzr\n"
    reset_index = source.find(reset, marker_index)
    diagnostic_index = source.find("#ifdef REIX_FPSIMD_DIAGNOSTIC", marker_index)
    if reset_index < 0 or diagnostic_index < 0 or reset_index > diagnostic_index:
        raise RuntimeError("canonical mutation no longer identifies the handler reset")

    return source[:reset_index] + source[reset_index + len(reset):]


def mutate_nested_probe(source: str, mode: str) -> str:
    if mode != "guard":
        return source

    entry = "fpsimd_run_nested_probe:\n"
    if source.count(entry) != 1:
        raise RuntimeError("guard probe no longer identifies its entry point")

    fault = """fpsimd_run_nested_probe:
    // Leave less than one trap frame on the kernel stack and wait for an IRQ.
    // The vector must switch to the exception stack and fail closed. If it
    // incorrectly returns, x0 changes from 0x1111 to 0xDEAD before a guard-page
    // fault forces a second report, making the bad return visible in its dump.
    adrp    x9, __stack_bottom
    add     x9, x9, :lo12:__stack_bottom
    add     sp, x9, #512
    adrp    x11, fpsimd_diagnostic_nested_status
    add     x11, x11, :lo12:fpsimd_diagnostic_nested_status
    str     xzr, [x11]
    mov     x0, #0x1111
    msr     daifclr, #2
    isb
.L_guard_wait_for_irq:
    wfi
    ldr     x12, [x11]
    cbz     x12, .L_guard_wait_for_irq
    msr     daifset, #2

    mov     x0, #0xDEAD
    sub     x10, x9, #8
    str     xzr, [x10]
.L_guard_fault_returned:
    b       .L_guard_fault_returned
"""
    return source.replace(entry, fault)


def replace_user_apps(
    workspace: Path,
    output: Path,
    clang: str,
    llvm_ar: str,
    build_path: str,
) -> None:
    probe = workspace / "Tests/GuestProbes/FPContextUser.S"
    objects = {
        "Init": output / "fp-context-root.o",
        "StorageCheck": output / "fp-context-child.o",
    }

    for app, object_file in objects.items():
        root_probe = "1" if app == "Init" else "0"
        subprocess.run(
            [
                clang,
                f"--target={TRIPLE}",
                "-c",
                "-x",
                "assembler-with-cpp",
                f"-DROOT_PROBE={root_probe}",
                "-DPERF_ONLY=0",
                str(probe),
                "-o",
                str(object_file),
            ],
            check=True,
        )

        archive = (
            workspace
            / build_path
            / TRIPLE
            / "debug"
            / f"lib{app}.a"
        )
        archive.unlink()
        subprocess.run([llvm_ar, "rcs", str(archive), str(object_file)], check=True)


def replace_benchmark_apps(
    workspace: Path,
    output: Path,
    clang: str,
    llvm_ar: str,
    build_path: str,
) -> None:
    probe = workspace / "Tests/GuestProbes/FPContextYieldPeer.S"
    objects = {
        "Init": output / "fp-peer-root.o",
        "StorageCheck": output / "fp-peer-child.o",
    }

    for app, object_file in objects.items():
        root_probe = "1" if app == "Init" else "0"
        subprocess.run(
            [
                clang,
                f"--target={TRIPLE}",
                "-c",
                "-x",
                "assembler-with-cpp",
                f"-DROOT_PROBE={root_probe}",
                str(probe),
                "-o",
                str(object_file),
            ],
            check=True,
        )

        archive = workspace / build_path / TRIPLE / "debug" / f"lib{app}.a"
        archive.unlink()
        subprocess.run([llvm_ar, "rcs", str(archive), str(object_file)], check=True)


def run_guest(
    *,
    mode: str,
    workspace: Path,
    output: Path,
    qemu: str,
    timeout: float,
) -> dict[str, object]:
    log = output / f"{mode}-serial.log"
    image = workspace / ".reix/kernel.bin"
    archived_image = output / f"{mode}-kernel.bin"
    shutil.copy2(image, archived_image)

    command = [
        qemu,
        "-machine",
        "virt,gic-version=2",
        "-cpu",
        "cortex-a53,pmu=on",
        "-nographic",
        "-m",
        "4M",
        "-kernel",
        str(image),
    ]
    if mode == "benchmark":
        command += ["-icount", "shift=0,align=off,sleep=off"]
    started = time.monotonic()

    with log.open("wb") as output_file:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=output_file,
            stderr=subprocess.STDOUT,
        )
        try:
            complete = False
            while time.monotonic() - started < timeout:
                data = log.read_text(errors="replace")
                if mode == "benchmark":
                    complete = "[ FP PEER BENCH DONE ]" in data
                elif mode == "normal":
                    complete = all(
                        marker in data
                        for marker in (
                            "[FPSIMD] nested EL1 state and kernel FP environment preserved.",
                            "[ FP RAW root PASS ]",
                            "[ FP RAW child PASS ]",
                            "[ FP RAW split parent PASS ]",
                            "[ FP RAW split child PASS ]",
                        )
                    )
                elif mode == "restore":
                    complete = (
                        "[ FP RAW root MISMATCH ] word=0000000000000012" in data
                        and "[ FP RAW root FAIL ]" in data
                    )
                elif mode == "canonical":
                    complete = (
                        "FP/SIMD diagnostic: Swift inherited non-canonical FP state" in data
                        and "=== REIX-PANIC END - SYSTEM HALTED ===" in data
                    )
                else:
                    complete = all(
                        marker in data
                        for marker in (
                            "Kernel stack overflow (insufficient room for an exception frame)",
                            "registers",
                            "x0-x3  : 0x1111",
                            "=== REIX-PANIC END - SYSTEM HALTED ===",
                        )
                    ) and "x0-x3  : 0xdead" not in data

                if complete or process.poll() is not None:
                    break
                time.sleep(0.05)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    data = log.read_text(errors="replace")
    samples: list[int] = []
    if mode == "benchmark":
        samples = [
            int(value, 16)
            for value in re.findall(r"FP_PEER_TICKS value=([0-9a-f]{16})", data)
        ]
        passed = (
            complete
            and len(samples) == 21
            and "[ FP PEER READY ]" in data
            and "REIX-PANIC" not in data
            and "FP PEER BENCH SPAWN FAIL" not in data
        )
    elif mode == "normal":
        passed = (
            complete
            and "REIX-PANIC" not in data
            and "MISMATCH" not in data
            and "[ FP RAW root FAIL ]" not in data
            and "[ FP RAW child FAIL ]" not in data
        )
    else:
        # A negative control passes only when the unmodified oracle rejects the
        # deliberately broken exception boundary in the expected way.
        passed = complete

    result: dict[str, object] = {
        "mode": mode,
        "passed": passed,
        "seconds": time.monotonic() - started,
        "log": str(log),
        "kernel": str(archived_image),
        "command": command,
    }
    if samples:
        result["samples"] = samples
        result["median"] = statistics.median(samples)
        result["iterationsPerSample"] = 10_000
        result["minimumTransitionsPerIteration"] = 2
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("all",) + MODES,
        default="all",
        help="oracle, negative control, guard panic, peer benchmark, or all (default)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="new empty evidence directory (default: a temporary directory)",
    )
    parser.add_argument("--timeout", type=float, default=30)
    arguments = parser.parse_args()

    source = Path(__file__).resolve().parent.parent
    if arguments.output is None:
        evidence = Path(tempfile.mkdtemp(prefix="reix-fpsimd-context-"))
    else:
        evidence = arguments.output.resolve()
        if evidence.exists() and any(evidence.iterdir()):
            raise RuntimeError(f"output directory is not empty: {evidence}")
        evidence.mkdir(parents=True, exist_ok=True)

    workspace = evidence / "workspace"
    workspace.mkdir()

    swift = tool("REIX_SWIFT", "swift")
    clang = tool("REIX_CLANG", "clang")
    llvm_ar = tool("REIX_LLVM_AR", "llvm-ar")
    qemu = tool("REIX_QEMU", "qemu-system-aarch64")
    git = tool("REIX_GIT", "git")

    snapshot(source, workspace, git)
    selected_modes = MODES if arguments.mode == "all" else (arguments.mode,)

    environment = dict(os.environ)
    environment.pop("REIX_FPSIMD_DIAGNOSTIC", None)
    environment.update(
        FREESTANDING="1",
        CLANG_MODULE_CACHE_PATH=str(evidence / "module-cache-clang"),
        SWIFTPM_MODULECACHE_OVERRIDE=str(evidence / "module-cache-swift"),
    )
    diagnostic_environment = {
        **environment,
        "REIX_FPSIMD_DIAGNOSTIC": "1",
    }

    if any(mode != "benchmark" for mode in selected_modes):
        run_logged(
            [
                swift,
                "build",
                "--disable-sandbox",
                "--triple",
                TRIPLE,
                "--scratch-path",
                "build-cross",
            ],
            cwd=workspace,
            environment=diagnostic_environment,
            log=evidence / "cross-build.log",
        )

    if "benchmark" in selected_modes:
        run_logged(
            [
                swift,
                "build",
                "--disable-sandbox",
                "--triple",
                TRIPLE,
                "--scratch-path",
                "build-cross-benchmark",
            ],
            cwd=workspace,
            environment=environment,
            log=evidence / "benchmark-cross-build.log",
        )
    context_saving = (
        workspace
        / "Sources/ReixKernel/Arch/aarch64/Exceptions/Handlers/ContextSaving.S"
    )
    original_context_saving = context_saving.read_text()
    nested_probe = workspace / "Tests/GuestProbes/FPContextNested.S"
    original_nested_probe = nested_probe.read_text()
    results: list[dict[str, object]] = []

    for mode in selected_modes:
        if mode == "benchmark":
            build_path = "build-cross-benchmark"
            mode_environment = environment
            replace_benchmark_apps(
                workspace, evidence, clang, llvm_ar, build_path
            )
        else:
            build_path = "build-cross"
            mode_environment = diagnostic_environment
            replace_user_apps(
                workspace, evidence, clang, llvm_ar, build_path
            )
        context_saving.write_text(mutate_context_saving(original_context_saving, mode))
        nested_probe.write_text(mutate_nested_probe(original_nested_probe, mode))
        run_logged(
            [
                swift,
                "package",
                "--disable-sandbox",
                "--scratch-path",
                f"build-plugin-{mode}",
                "--allow-writing-to-package-directory",
                "reix",
            ],
            cwd=workspace,
            environment={**mode_environment, "REIX_BUILD_PATH": build_path},
            log=evidence / f"{mode}-link.log",
        )
        result = run_guest(
            mode=mode,
            workspace=workspace,
            output=evidence,
            qemu=qemu,
            timeout=arguments.timeout,
        )
        results.append(result)
        print(json.dumps(result))

    summary = {
        "passed": all(bool(result["passed"]) for result in results),
        "workspace": str(workspace),
        "results": results,
    }
    (evidence / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"evidence: {evidence}")
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"fpsimd-context: {error}", file=sys.stderr)
        raise SystemExit(2)
