#!/bin/sh
#
# prune-stale.sh
# ReixOS
#
# Removes the build directory when it holds objects whose source is gone.
#
# SwiftPM leaves the compiled object of a deleted or renamed source behind, and
# the static archives keep it as a member, so the linker is handed the same type
# twice: once from the file that no longer exists and once from whatever
# replaced it. The failure surfaces as a wall of `duplicate symbol` lines naming
# a file that is not in the tree any more, which is about as far from the cause
# as an error can point.
#
# Deleting the orphan objects is not enough on its own: an archive is not
# rebuilt while none of its sources changed, so it goes on offering the stale
# member. The whole directory goes instead, which costs one full rebuild on the
# rare build that follows a deletion and nothing at all on every other.
#
# Only `.swift.o` and `.c.o` under a target's own build directory are examined.
# The plugin's generated assembly lives elsewhere and is regenerated per build,
# so it cannot go stale this way.
#
# The build directory is searched for sources too, and has to be: SwiftPM writes
# generated ones there, `runner.swift` for the test bundle among them, and their
# objects are no more stale than any other.
#
# Usage:
#     sh scripts/prune-stale.sh
#
# Environment:
#   BUILD   build directory   (default: .build)
#   ROOTS   source roots      (default: "Sources Tests Plugins", plus $BUILD)
#
# Exit code is always 0: this is hygiene, not a check, and a tree with nothing
# built yet is a perfectly good starting point.

set -u

BUILD="${BUILD:-.build}"
ROOTS="${ROOTS:-Sources Tests Plugins}"

[ -d "$BUILD" ] || exit 0

work=$(mktemp -d "${TMPDIR:-/tmp}/reix-prune.XXXXXX") || exit 0
trap 'rm -rf "$work"' EXIT INT TERM

# Every source name that exists, once. Names and not paths: a file that moved
# between directories is not stale, and its object is still the right one.
present="$work/present"
: > "$present"
for root in $ROOTS "$BUILD"; do
    [ -d "$root" ] || continue
    find "$root" \( -name '*.swift' -o -name '*.c' \) -type f 2>/dev/null \
        | while IFS= read -r source; do basename "$source"; done >> "$present"
done
sort -u -o "$present" "$present"

stale="$work/stale"
: > "$stale"

# `*/*/*.build` covers both debug and release under every triple, and reaches no
# further: the plugin's outputs are not in a target build directory.
find "$BUILD" -path "$BUILD/*/*/*.build/*" \
     \( -name '*.swift.o' -o -name '*.c.o' \) -type f 2>/dev/null \
| while IFS= read -r object; do
    name=$(basename "$object" .o)
    grep -qxF "$name" "$present" || printf '%s\n' "$object" >> "$stale"
done

[ -s "$stale" ] || exit 0

echo "prune-stale: objects with no source left in $BUILD:"
sed 's/^/    /' "$stale"
echo "prune-stale: removing $BUILD so the archives are rebuilt without them."

rm -rf "$BUILD"
exit 0
