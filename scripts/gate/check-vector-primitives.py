#!/usr/bin/env python3
#
# check-vector-primitives.py
# ReixOS
#
# The `vector-primitives` post-check: memcpy, memset and memmove read out of
# every linked ELF, kernel and programs alike.
#
# The source cannot promise any of this, because the compiler decides it. Loop
# idiom recognition turns a byte loop back into a call to memset, and inside
# memset that call is a recursion no QEMU row can tell from a hang. A vector
# loop the optimiser dropped is slower and still correct. So the image is read:
#
#   1. no memcpy, memset or memmove reaches itself or one of the others;
#   2. nothing they reach calls through a register;
#   3. RawBytes.fill and RawBytes.copy, where an ELF still has them, move q
#      registers (and copy d registers for the 8-byte skew);
#   4. `dc zva` lives only in the kernel's `zero_blocks`, reached only from the
#      memset path, and DCZID_EL0 is read only by `read_dczid`, reached only
#      from boot. No program holds either.
#
# Usage:
#     check-vector-primitives.py OBJDUMP KERNEL_ELF [ELF...]
#
# Prints what it read per ELF on stdout. Exits 1 with a one-line reason on the
# last line when a rule is broken, 2 when an ELF cannot be read.

import os
import re
import subprocess
import sys


ROOTS = ("memcpy", "memset", "memmove")
HEADER = re.compile(r"^[0-9a-f]+ <(.+)>:$")
BRANCH = re.compile(r"^(?:b|bl|b\.\w+|cbn?z|tbn?z)$")
TARGET = re.compile(r"<([^>+]+)(?:\+0x[0-9a-f]+)?>")


def disassemble(objdump, elf):
    """Function name to its list of (mnemonic, operands)."""
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
            current = header.group(1)
            functions.setdefault(current, [])
            continue
        if current is None or ":" not in line:
            continue
        fields = line.split(":", 1)[1].split(None, 1)
        if fields:
            functions[current].append((fields[0], fields[1] if len(fields) > 1 else ""))
    return functions


def callees(functions, name):
    found = set()
    for mnemonic, operands in functions.get(name, ()):
        if not BRANCH.match(mnemonic):
            continue
        target = TARGET.search(operands)
        if target and (target.group(1) != name or (mnemonic == "bl" and "+0x" not in target.group(0))):
            found.add(target.group(1))
    return found


def reachable(functions, root):
    """Every function `root` reaches, each with the path that got there."""
    paths, pending = {root: [root]}, [root]
    while pending:
        name = pending.pop()
        for callee in sorted(callees(functions, name)):
            if callee not in paths:
                paths[callee] = paths[name] + [callee]
                pending.append(callee)
    return paths


def body(functions, needle):
    for name, instructions in functions.items():
        if needle in name:
            return name, " ".join(f"{m} {o}" for m, o in instructions)
    return None, ""


def check(objdump, elf, kernel):
    functions = disassemble(objdump, elf)
    roots = [root for root in ROOTS if root in functions]

    for root in roots:
        paths = reachable(functions, root)
        for other in ROOTS:
            if other == root:
                continue
            if other in paths:
                return f"{root} reaches {other}: {' -> '.join(paths[other])}"
        # Loop branches inside a function are dropped; a `bl` to its own start
        # is kept, since that is recursion.
        for name in paths:
            if root in callees(functions, name):
                return f"{root} reaches itself: {' -> '.join(paths[name] + [root])}"
        for name in paths:
            if any(m == "blr" for m, _ in functions.get(name, ())):
                return f"{root} reaches an indirect call in {name}"
        print(f"  {root}: reaches {len(paths)} functions, none of them a mem* entry")

    name, text = body(functions, "8RawBytesO4fill")
    if name:
        if not re.search(r"\bdup v\d+\.", text) or not re.search(r"\b(stp q|str q)", text):
            return f"{name} does not fill with a dup'ed q register"
        print(f"  {name}: dup + q stores")

    name, text = body(functions, "8RawBytesO4copy2to")
    if name:
        for shape in ("ldp q", "stp q", "ldp d", "stp d"):
            if not re.search(r"\b" + shape, text):
                return f"{name} has no {shape}"
        print(f"  {name}: ldp/stp of q and d")

    zva   = holders(functions, lambda m, o: m == "dc" and o.lower().startswith("zva"))
    dczid = holders(functions, lambda m, o: m == "mrs" and "dczid_el0" in o.lower())
    if not kernel:
        if zva or dczid:
            return f"a program holds dc zva or reads DCZID_EL0: {sorted(zva | dczid)}"
        return None

    if zva != {"zero_blocks"}:
        return f"dc zva outside zero_blocks: {sorted(zva)}"
    if dczid != {"read_dczid"}:
        return f"DCZID_EL0 read outside read_dczid: {sorted(dczid)}"

    # The compiler may inline zeroCacheBlocks into the memset body, and
    # loadCacheType into boot, the way post_icache_batch allows for CTR_EL0.
    for routine, allowed in (("zero_blocks", ("zeroCacheBlocks", "kernelMemset")),
                             ("read_dczid", ("loadCacheType", "VirtualMemoryManagerV6ppmPtr"))):
        found = callers(functions, routine)
        stray = [name for name in found if not any(a in name for a in allowed)]
        if not found or stray:
            return f"{routine} is reached from outside {' or '.join(allowed)}: {sorted(found)}"
        print(f"  {routine}: called only from {sorted(found)}")

    return None


def holders(functions, matches):
    return {name for name, instructions in functions.items()
            if any(matches(m, o) for m, o in instructions)}


def callers(functions, routine):
    return {name for name in functions if name != routine and routine in callees(functions, name)}


def main():
    if len(sys.argv) < 3:
        print("usage: check-vector-primitives.py OBJDUMP KERNEL_ELF [ELF...]")
        sys.exit(2)

    objdump, seen = sys.argv[1], set()
    for index, elf in enumerate(sys.argv[2:]):
        if os.path.realpath(elf) in seen:
            continue
        seen.add(os.path.realpath(elf))
        print(elf)
        failure = check(objdump, elf, kernel=index == 0)
        if failure:
            print(f"{elf}: {failure}")
            sys.exit(1)

    print(f"{len(seen)} ELFs: no mem* recursion, no indirect call, vector shapes present")


if __name__ == "__main__":
    main()
