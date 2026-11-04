#!/usr/bin/env python3
#
# check-aggregate-copies.py
# ReixOS
#
# The `aggregate-copies` post-check: no syscall, IPC or exception path in the
# kernel copies a whole capability table, trap frame or address-space manager
# to read a few bytes of it.
#
# The source cannot promise this either. A non-mutating method on a struct that
# holds an InlineArray gets a copy of `self` whenever the compiler cannot prove
# the original addressable, and passing a trap frame by value does the same. The
# copy is a constant-size memcpy or memmove, so the image is read:
#
#   1. no checked function calls memcpy or memmove with a constant of 256 bytes
#      or more, directly or through an outlined helper that sets the size;
#   2. no checked function stores eight or more q registers, which is what the
#      same copy looks like when the compiler inlines it;
#   3. every pattern below still names a function, so a rename cannot empty the
#      check in silence.
#
# Accessors and initialisers are exempt, and so is `cloneCapsTable`: there the
# copy is the operation, not a reader's temporary.
#
# Usage:
#     check-aggregate-copies.py OBJDUMP KERNEL_ELF
#
# Prints every checked function it read on stdout. Exits 1 with a one-line
# reason on the last line when a rule is broken, 2 when the ELF cannot be read.

import re
import subprocess
import sys


LIMIT = 256
Q_STORES = 8

CHECKED = (
    r"V6handle5frame7context",
    r"Syscall[VO]",
    r"^\$e6Kernel14SyscallHandlerV",
    r"^\$e6Kernel13RendezvousIPCV",
    r"^\$e6Kernel9CapsTableV",
    r"^\$e6Kernel12DeviceAccessO",
    r"^\$e6Kernel18InterruptAuthorityO",
    r"^\$e6Kernel9BusAccessO",
    r"^\$e6Kernel20TaskCapabilityAccessO",
    r"^\$e6Kernel8DmaAllocV",
    r"^\$e6Kernel20ProfileAuthorizationO",
    r"^\$e6Kernel10UserMemoryV",
    r"^\$e6Kernel10VMAManagerV",
    r"^\$e6Kernel13VirtioBusInfoV9transport",
    r"exceptionVirtualTableHandler",
    r"^\$e6Kernel20performPendingSwitch",
    r"^\$e6Kernel28VirtualTimerInterruptHandlerV",
    r"^\$e6Kernel19InterruptDispatcherV",
)
EXEMPT = (
    r"(v[gs]Z?|cfC|pfi|cfcfA_)$",
    r"RendezvousIPCV14cloneCapsTable",
)

HEADER = re.compile(r"^([0-9a-f]+) <(.+)>:$")
TARGET = re.compile(r"^(?:0x)?([0-9a-f]+) <([^>+]+)>")
SIZE = re.compile(r"^[wx]2, #(0x[0-9a-f]+|\d+)")
COPIES = ("memcpy", "memmove")


def disassemble(objdump, elf):
    """Function start address to (name, [(mnemonic, operands)])."""
    result = subprocess.run(
        [objdump, "-d", "--no-show-raw-insn", elf],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"could not disassemble {elf}: {result.stderr.strip()}")
        sys.exit(2)

    functions, current = {}, None
    for line in result.stdout.splitlines():
        header = HEADER.match(line)
        if header:
            current = int(header.group(1), 16)
            functions[current] = (header.group(2), [])
            continue
        if current is None or ":" not in line:
            continue
        fields = line.split(":", 1)[1].split(None, 1)
        if fields:
            functions[current][1].append((fields[0], fields[1].strip() if len(fields) > 1 else ""))
    return functions


def copies(functions, body):
    """Constant-size memcpy/memmove calls in `body`, and its q-register stores.

    Outlined helpers are followed one level: -Osize moves the `mov w2, #N` of a
    copy, or the branch to memcpy itself, into a shared OUTLINED_FUNCTION.
    """
    found, size, q_stores = [], None, 0
    for mnemonic, operands in body:
        constant = SIZE.match(operands)
        if mnemonic == "mov" and constant:
            size = int(constant.group(1), 0)
            continue
        if mnemonic == "stp" and operands.startswith("q"):
            q_stores += 1
        if mnemonic not in ("b", "bl"):
            continue
        target = TARGET.match(operands)
        if not target:
            continue
        address, name = int(target.group(1), 16), target.group(2)
        if name in COPIES:
            found.append((name, size))
        elif name.startswith("OUTLINED_FUNCTION") and address in functions:
            for inner, inner_operands in functions[address][1]:
                constant = SIZE.match(inner_operands)
                if inner == "mov" and constant:
                    size = int(constant.group(1), 0)
                inner_target = TARGET.match(inner_operands) if inner in ("b", "bl") else None
                if inner_target and inner_target.group(2) in COPIES:
                    found.append((inner_target.group(2), size))
            continue
        if mnemonic == "bl":
            size = None
    return found, q_stores


def main():
    if len(sys.argv) != 3:
        print("usage: check-aggregate-copies.py OBJDUMP KERNEL_ELF")
        sys.exit(2)

    functions = disassemble(sys.argv[1], sys.argv[2])
    names = [name for name, _ in functions.values()]

    for pattern in CHECKED:
        if not any(re.search(pattern, name) for name in names):
            print(f"no function matches {pattern}: renamed, or the check went stale")
            sys.exit(1)

    checked = 0
    for name, body in functions.values():
        if not any(re.search(pattern, name) for pattern in CHECKED):
            continue
        if any(re.search(pattern, name) for pattern in EXEMPT):
            continue
        checked += 1
        found, q_stores = copies(functions, body)
        large = [(callee, size) for callee, size in found if size is not None and size >= LIMIT]
        if large:
            callee, size = large[0]
            print(f"{name} copies an aggregate: {callee} of {size} bytes")
            sys.exit(1)
        if q_stores >= Q_STORES:
            print(f"{name} stores {q_stores} q registers, an inlined aggregate copy")
            sys.exit(1)
        print(f"  {name}")

    print(f"{checked} functions on the syscall, IPC and exception paths: no aggregate copy")


if __name__ == "__main__":
    main()
