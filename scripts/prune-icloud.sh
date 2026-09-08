#!/bin/sh
#
# prune-icloud.sh
# ReixOS
#
# Removes the copies iCloud leaves behind in the source tree.
#
# A sync conflict is resolved by writing a second file beside the first, named
# `Thing 2.swift`. SwiftPM compiles it: the module then declares every type in
# it twice and the build dies on `invalid redeclaration`, pointing at a file
# nobody wrote. `make prune-dups` already sweeps the build trees; this sweeps
# the sources, where the copies are the cause rather than the symptom.
#
# A copy is removed only when it is byte for byte the file it was copied from.
# Anything else is reported and left alone: a copy that differs may be the one
# holding somebody's work, and this is hygiene, not a merge tool.
#
# Usage:
#     sh scripts/prune-icloud.sh
#
# Environment:
#   ROOTS   directories to sweep (default: "Sources Tests Tools Plugins scripts")
#
# Exit code is 0 when everything found was identical and removed, and 1 when a
# copy was kept, so a caller can tell "clean" from "somebody has to look".

set -u

ROOTS="${ROOTS:-Sources Tests Tools Plugins scripts}"

removed=0
kept=0

for root in $ROOTS; do
    [ -d "$root" ] || continue
    # `Thing 2.swift`, `Thing 3.json`: a space, digits, then the extension.
    find "$root" -name "* [0-9].*" -type f 2>/dev/null | while IFS= read -r copy; do
        original=$(printf '%s\n' "$copy" | sed -E 's/ [0-9]+(\.[^.]+)$/\1/')
        if [ ! -f "$original" ]; then
            echo "prune-icloud: kept (nothing to compare with): $copy"
            continue
        fi
        if cmp -s "$copy" "$original"; then
            rm -f "$copy"
            echo "prune-icloud: removed $copy"
        else
            echo "prune-icloud: kept (differs from $original): $copy"
        fi
    done
done

# The loop above runs in a subshell per root, so the counts cannot come back
# from it. Ask the tree instead: what is left is what was kept.
for root in $ROOTS; do
    [ -d "$root" ] || continue
    kept=$((kept + $(find "$root" -name "* [0-9].*" -type f 2>/dev/null | wc -l)))
done

[ "$kept" -eq 0 ] || echo "prune-icloud: $kept copy or copies left for somebody to look at"
[ "$kept" -eq 0 ]
