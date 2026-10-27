#!/bin/sh
#
# structural-gate.sh
# ReixOS
#
# Compares a freshly built kernel.bin and initrd.tar against a pinned baseline
# and reports whether the build front end still produces the same artifacts.
#
# It does not compare hashes, and that is not a concession. The plan for the
# `reix` port opened with a sha256 gate, on the reasoning that UstarWriter pins
# mtime/uid/gid to zero and `objcopy -O binary` carries no paths. Both are true
# and the conclusion was still wrong: the Swift compiler injects a per
# compilation opaque value into every module, so three builds of frozen sources
# give three different hashes. Measured, not assumed - a warm rebuild of an
# untouched tree differs from its own predecessor in 559 bytes, spread over 36
# runs, and not one of those runs is longer than 16 bytes.
#
# So the test is structural instead. Three things a port bug cannot leave alone
# and an opaque module stamp cannot disturb:
#
#   * every artifact has exactly the byte length it had before;
#   * the archive lists the same members, in the same order, at the same
#     lengths;
#   * every differing byte sits in a short run, because the compiler's stamp is
#     a fixed 16-byte field and a real code or link difference is not.
#
# What this does not prove is that the image still boots. Nothing here executes
# anything, so `make smoke` is the other half and always was: a same-size binary
# can still be linked wrong. Run both.
#
# The baseline goes stale the moment anyone edits Sources/ or Native/, which is
# why no make target runs this. It is a tool for the deliberate question "did
# changing the build change the build's output", asked after a build system
# change and answered against a baseline you re-pin on purpose.
#
# Usage:
#     ./reix build && sh scripts/structural-gate.sh [baseline-directory]
#
# Environment:
#   OUT      build output directory  (default: .reix)
#   MAX_RUN  longest tolerated run of differing bytes, in bytes (default: 16)
#
# Exit codes: 0 pass, 1 a check failed, 3 setup error (a file is missing).

set -u

BASELINE="${1:-Tests/Fixtures/build-baseline}"
OUT="${OUT:-.reix}"
MAX_RUN="${MAX_RUN:-16}"

work=$(mktemp -d "${TMPDIR:-/tmp}/reix-structural-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

status=0

fail() {
    echo "FAIL: $1" >&2
    status=1
}

for name in kernel.bin initrd.tar; do
    if [ ! -f "$BASELINE/$name" ]; then
        echo "SETUP: no baseline at $BASELINE/$name" >&2
        exit 3
    fi
    if [ ! -f "$OUT/$name" ]; then
        echo "SETUP: missing build output ($OUT/$name) - run './reix build' first" >&2
        exit 3
    fi
done

for name in kernel.bin initrd.tar; do
    base="$BASELINE/$name"
    built="$OUT/$name"

    base_size=$(wc -c < "$base" | tr -d ' ')
    built_size=$(wc -c < "$built" | tr -d ' ')
    if [ "$base_size" != "$built_size" ]; then
        fail "$name is $built_size bytes, baseline is $base_size"
        continue
    fi

    # `cmp -l` gives one line per differing byte, so consecutive offsets are a
    # run. A stamp is one short run; a moved function is a long one.
    set -- $(cmp -l "$base" "$built" | awk '
        NR == 1 { bytes = 1; runs = 1; run = 1; prev = $1; next }
        {
            if ($1 == prev + 1) {
                run++
            } else {
                if (run > longest) longest = run
                runs++
                run = 1
            }
            prev = $1
            bytes++
        }
        END {
            if (run > longest) longest = run
            printf "%d %d %d\n", bytes + 0, runs + 0, longest + 0
        }')
    bytes=$1
    runs=$2
    longest=$3

    echo "  $name  $base_size B, $bytes differing in $runs runs, longest $longest"
    if [ "$longest" -gt "$MAX_RUN" ]; then
        fail "$name has a $longest byte run of differences, over the $MAX_RUN byte ceiling"
    fi
done

# The archive's member table is the part no opaque stamp can move: a member
# gained, lost, reordered or resized is a packing bug and nothing else.
if ! tar tvf "$BASELINE/initrd.tar" > "$work/baseline.table" 2>"$work/tar.err"; then
    echo "SETUP: could not list $BASELINE/initrd.tar" >&2
    cat "$work/tar.err" >&2
    exit 3
fi
if ! tar tvf "$OUT/initrd.tar" > "$work/built.table" 2>"$work/tar.err"; then
    echo "SETUP: could not list $OUT/initrd.tar" >&2
    cat "$work/tar.err" >&2
    exit 3
fi

if diff -u "$work/baseline.table" "$work/built.table" > "$work/table.diff"; then
    echo "  initrd.tar  member table identical ($(wc -l < "$work/baseline.table" | tr -d ' ') members)"
else
    fail "initrd.tar member table differs from the baseline"
    cat "$work/table.diff" >&2
fi

if [ "$status" -eq 0 ]; then
    echo "PASS: structurally identical to $BASELINE"
else
    echo "structural gate failed against $BASELINE" >&2
fi
exit "$status"
