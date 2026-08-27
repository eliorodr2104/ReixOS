#!/bin/sh
#
# scenarios.sh
# ReixOS
#
# Boots the matrix in Tests/Scenarios/scenarios.tsv and turns each serial log
# into a verdict, instead of one hand-typed `make smoke` per configuration.
#
# The boot engine is scripts/smoke.sh, untouched: this script only composes its
# environment, so a matrix row and `make smoke` start the guest exactly the same
# way and there is one place that knows how to launch and reap QEMU. What is
# added on top is the marker language (a chain that must appear in order, a set
# that must not), the expectation vocabulary (pass, xfail, skip) and reporting.
#
# Strictly one row at a time, by design and not by omission: QEMU is a single
# writer here. Every row boots the same machine from the same $OUT, so two
# guests at once would race for the build output and for the host's cycles, and
# the timing-sensitive rows would start failing for reasons that are not theirs.
#
# Artifacts, kept whether a row passed or failed:
#   $OUT/scenario-<id>.log        the guest's serial output
#   $OUT/scenario-<id>.post.txt   a post-check's output, when the row has one
#   $OUT/scenario-results.xml     JUnit, alongside the host suite's xUnit report
#
# Usage:
#     sh scripts/scenarios.sh          # the whole matrix
#     sh scripts/scenarios.sh no-pmu   # one row, by id
#
# Environment:
#   SCENARIOS   matrix file           (default: Tests/Scenarios/scenarios.tsv)
#   OUT         output directory      (default: .reix)
#   QEMU        QEMU binary           (passed through to the engine)
#   QEMU_FLAGS  base machine flags every row appends to
#   SWIFT       host toolchain used by the post-checks (default: swift)
#   OBJDUMP     disassembler used by the post-checks (default: llvm-objdump)
#
# Exit codes: 0 every row behaved as declared, 1 a row failed or an xfail row
# unexpectedly passed, 3 setup error (missing matrix or image, unreadable row).

set -u

SCENARIOS="${SCENARIOS:-Tests/Scenarios/scenarios.tsv}"
OUT="${OUT:-.reix}"
SWIFT="${SWIFT:-swift}"
OBJDUMP="${OBJDUMP:-llvm-objdump}"
ENGINE="${ENGINE:-scripts/smoke.sh}"
# Keep in sync with QEMU_FLAGS in the Makefile and in scripts/smoke.sh. `make
# vm-test` passes the Makefile's copy in, so this default only ever serves a
# bare `sh scripts/scenarios.sh` from a developer's shell.
QEMU_FLAGS="${QEMU_FLAGS:--machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic}"

# Ceiling on the kernel stack high-water figure the trace dump reports, in
# bytes. Deliberately far below the size `.stack` gets in linker.ld: the two
# numbers are a warning line and a hard wall, and the gap between them is the
# room a regression has to be caught in. A row failing here means some path
# started eating stack, which is a bug to find while the machine still boots,
# rather than the guard-page panic the same growth becomes once it clears the
# wall. Raise it only together with the section, and only on evidence.
STACK_CEILING="${STACK_CEILING:-16384}"

REPORT="$OUT/scenario-results.xml"
FILTER="${1:-}"
TAB=$(printf '\t')

passed=0
failed=0
xfailed=0
skipped=0
selected=0

work=$(mktemp -d "${TMPDIR:-/tmp}/reix-scenarios.XXXXXX") || exit 3
trap 'rm -rf "$work"' EXIT
trap 'rm -rf "$work"; exit 130' INT TERM

cases="$work/cases.xml"
failures="$work/failures.txt"
: > "$cases"
: > "$failures"


# MARK: - helpers

# The leading newline terminates the half-written progress line of whichever row
# raised this, so the message does not land at the end of it.
setup_error() {
    printf '\nSETUP: %s\n' "$1" >&2
    exit 3
}

# Escapes the five XML metacharacters on the way into an attribute or a body.
xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

xml_attr() {
    printf '%s' "$1" | xml_escape | tr -d '\n'
}

# Prints a `|`-separated marker list one marker per line.
#
# Globbing is off around the split on purpose: markers like `[ SERVE ] running`
# are valid glob patterns, and `[ SERVE ]` would happily expand to a file named
# `S` in the working directory.
split_markers() {
    sm_list=$1
    set -f
    IFS='|'
    # shellcheck disable=SC2086 # deliberate split on IFS
    set -- $sm_list
    unset IFS
    set +f
    printf '%s\n' "$@"
}

# Prints the first marker of the chain the log does not satisfy, and returns 1.
#
# The chain is a subsequence: each marker only has to appear on a line after the
# one that satisfied its predecessor, so unrelated output between two markers is
# fine and a marker printed too early is not.
check_required() {
    cr_log=$1
    [ "$2" = "-" ] && return 0

    cr_prev=0
    split_markers "$2" > "$work/req.txt"
    while IFS= read -r cr_marker <&4; do
        cr_line=$(grep -nF -- "$cr_marker" "$cr_log" 2>/dev/null \
                  | awk -F: -v min="$cr_prev" '$1 > min { print $1; exit }')
        if [ -z "$cr_line" ]; then
            printf '%s' "$cr_marker"
            return 1
        fi
        cr_prev=$cr_line
    done 4< "$work/req.txt"
    return 0
}

# Prints the first forbidden marker the log contains, and returns 1.
check_forbidden() {
    cf_log=$1
    [ "$2" = "-" ] && return 0

    split_markers "$2" > "$work/forbid.txt"
    while IFS= read -r cf_marker <&4; do
        if grep -qF -- "$cf_marker" "$cf_log" 2>/dev/null; then
            printf '%s' "$cf_marker"
            return 1
        fi
    done 4< "$work/forbid.txt"
    return 0
}


# MARK: - post-checks

# post=trace-boot: the kernel's own account of the boot, cross-checked against
# the console's. Init dumps the trace ring to the serial port; the decoder lives
# in the `reix` plugin, and every one of the eleven TraceBootPhase ids has to
# come back out of it in order.
#
# FREESTANDING selects the bare-metal flags in Package.swift and is cleared here
# for the same reason `make host-test` clears it: this is a host toolchain run.
post_trace_boot() {
    pt_log=$1
    pt_out=$2

    if ! FREESTANDING= "$SWIFT" package --allow-writing-to-package-directory \
            reix trace "$pt_log" --boot > "$pt_out" 2>&1; then
        printf 'the reix trace decoder failed, see %s' "$pt_out"
        return 1
    fi

    pt_prev=0
    for pt_phase in ppmReady vmmReady heapReady gicReady fsReady pmReady \
                    schedReady ipcReady syscallReady timerOn firstUser; do
        pt_line=$(grep -nF -- "$pt_phase" "$pt_out" 2>/dev/null \
                  | awk -F: -v min="$pt_prev" '$1 > min { print $1; exit }')
        if [ -z "$pt_line" ]; then
            printf 'boot phase %s missing or out of order in the decoded timeline' \
                   "$pt_phase"
            return 1
        fi
        pt_prev=$pt_line
    done

    # Field 4 of `  stack  : kernel N B, exception N B`, the figure boot.S's
    # poison makes measurable. Absent means the decoder changed shape, which is
    # a failure and not a pass: an unread ceiling guards nothing.
    pt_stack=$(awk '/^  stack  : kernel /{ print $4; exit }' "$pt_out")

    if [ -z "$pt_stack" ]; then
        printf 'no kernel stack figure in the decoded output'
        return 1
    fi

    if [ "$pt_stack" -gt "$STACK_CEILING" ]; then
        printf 'kernel stack high water %s B is over the %s B ceiling' \
               "$pt_stack" "$STACK_CEILING"
        return 1
    fi

    return 0
}

# post=dma-barriers: the virtqueue's memory barriers, read out of the linked
# image rather than out of the source.
#
# A barrier is the one thing in this system that cannot be unit tested: it has no
# result to compare and its absence shows up as a race on hardware nobody here
# runs. What can be checked is that the instructions are in the binary, that they
# are the outer-shareable ones the device needs rather than the inner-shareable
# one the console ring uses, and that the queue submission still calls them.
#
# So this is a regression net for deletion and for inlining, and it is honest
# about being no more than that.
post_dma_barriers() {
    pd_out=$2
    pd_elf=$OUT/BlockServer.elf

    if [ ! -f "$pd_elf" ]; then
        printf 'no %s to read the barriers out of' "$pd_elf"
        return 1
    fi

    "$OBJDUMP" -d "$pd_elf" > "$pd_out" 2>&1 || {
        printf 'could not disassemble %s' "$pd_elf"
        return 1
    }

    # The two instructions themselves, and the domain they name. Inner shareable
    # here would be a barrier that orders this core against other cores and not
    # against the device, which is the mistake worth catching.
    if ! grep -qE 'dmb[[:space:]]+oshst' "$pd_out"; then
        printf 'no outer-shareable store barrier in the block driver'
        return 1
    fi

    if ! grep -qE 'dmb[[:space:]]+oshld' "$pd_out"; then
        printf 'no outer-shareable load barrier in the block driver'
        return 1
    fi

    # And that the code that publishes and the code that reads a completion each
    # reach them, counted *inside* the function and not merely somewhere after
    # it. Publishing and collecting used to be one function; when the queue split
    # them this check went on passing while counting barriers across the whole
    # rest of the image, which is a check that had stopped saying anything.
    pd_writes=$(dma_barriers_in "$pd_out" '5offer' 'dma_write_barrier')
    pd_reads=$(dma_barriers_in "$pd_out" '7collect' 'dma_read_barrier')

    # Two writes: the descriptors before the available index, and that index
    # before the doorbell.
    if [ "$pd_writes" -lt 2 ]; then
        printf 'the queue publishes without both write barriers (%s found)' "$pd_writes"
        return 1
    fi

    if [ "$pd_reads" -lt 1 ]; then
        printf 'the queue reads a completion without a read barrier'
        return 1
    fi

    return 0
}

# Counts calls to $3 inside the one function whose symbol line matches $2.
#
# A disassembly labels each function with a line ending in `<name>:` and runs to
# the next such line, so the region is bounded rather than open ended.
dma_barriers_in() {
    awk -v want="$2" -v call="$3" '
        /^[0-9a-f]+ <.*>:$/ { inside = index($0, want) > 0 }
        inside && index($0, call) > 0 { n++ }
        END { print n + 0 }
    ' "$1"
}

run_post() {
    case $1 in
        -)          return 0 ;;
        trace-boot)   post_trace_boot "$2" "$3" ;;
        dma-barriers) post_dma_barriers "$2" "$3" ;;
        *)          setup_error "unknown post-check '$1'" ;;
    esac
}


# MARK: - expectations

# Returns 0 when the named condition holds and the row is to be skipped, with
# the human-readable why in $skip_reason. Add conditions here; an unknown one is
# a setup error rather than a silent pass, so a typo cannot hide a row.
skip_condition() {
    case $1 in
        no-host-swift)
            command -v "$SWIFT" >/dev/null 2>&1 && return 1
            skip_reason="no host Swift toolchain ('$SWIFT') for the post-check"
            return 0
            ;;
        *)
            setup_error "unknown skip condition '$1'"
            ;;
    esac
}


# MARK: - reporting

# One <testcase> per row. xfail is reported as skipped, which is what pytest and
# friends do with it: JUnit has no expected-failure state, and calling it a pass
# would hide it from anything reading only the XML.
emit_case() {
    ec_id=$1
    ec_state=$2
    ec_message=$3
    ec_seconds=$4
    ec_detail=$5

    {
        printf '    <testcase classname="scenario" name="%s" time="%s"' \
               "$(xml_attr "$ec_id")" "$ec_seconds"
        case $ec_state in
            passed)
                printf '/>\n'
                ;;
            failed)
                printf '>\n      <failure message="%s">' "$(xml_attr "$ec_message")"
                # The serial log carries the console's colour escapes, and a raw
                # ESC is not a legal XML character; tab and newline are kept.
                if [ -n "$ec_detail" ] && [ -f "$ec_detail" ]; then
                    tail -n 20 "$ec_detail" \
                        | LC_ALL=C tr -d '\001-\010\013\014\016-\037' \
                        | xml_escape
                fi
                printf '</failure>\n    </testcase>\n'
                ;;
            skipped|expected-fail)
                printf '>\n      <skipped type="%s" message="%s"/>\n    </testcase>\n' \
                       "$ec_state" "$(xml_attr "$ec_message")"
                ;;
        esac
    } >> "$cases"
}

write_report() {
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites>\n'
        printf '  <testsuite name="vm-scenarios" tests="%s" failures="%s" skipped="%s" time="%s">\n' \
               "$selected" "$failed" "$((xfailed + skipped))" "$1"
        cat "$cases"
        printf '  </testsuite>\n</testsuites>\n'
    } > "$REPORT"
}


# MARK: - main

[ -f "$SCENARIOS" ] || setup_error "no matrix at $SCENARIOS"
[ -f "$ENGINE" ]    || setup_error "no boot engine at $ENGINE"
mkdir -p "$OUT"

run_started=$(date +%s)

# The `|| [ -n "$id" ]` is not redundant: `read` reports failure on a last line
# with no trailing newline, having assigned the fields anyway, and without this
# the final row of a hand-edited matrix would be silently dropped.
while IFS="$TAB" read -r id mem initrd flags mode timeout required forbidden post expect <&3 \
      || [ -n "${id:-}" ]
do
    case $id in ''|\#*) continue ;; esac
    [ -n "$FILTER" ] && [ "$id" != "$FILTER" ] && continue

    [ -n "${expect:-}" ] || setup_error "row '$id' has fewer than ten columns"

    selected=$((selected + 1))
    printf 'scenarios:%s  ->  ' "$id"

    log="$OUT/scenario-$id.log"
    post_out="$OUT/scenario-$id.post.txt"
    engine_out="$work/engine-$id.txt"

    # skip-if is decided before the guest boots: the point of a skip is not
    # spending the 30s.
    skip_reason=
    case $expect in
        skip-if:*)
            if skip_condition "${expect#skip-if:}"; then
                skipped=$((skipped + 1))
                printf 'skipped: %s\n' "$skip_reason"
                emit_case "$id" skipped "$skip_reason" 0 ''
                continue
            fi
            ;;
    esac

    row_started=$(date +%s)

    # Flags are appended, never merged: QEMU keeps the last -cpu/-machine it is
    # handed, so a row overrides one without restating the base.
    row_flags="$QEMU_FLAGS"
    [ "$flags" = "-" ] || row_flags="$row_flags $flags"

    row_mem=""
    [ "$mem" = "-" ] || row_mem="$mem"

    # Two ways to end a run. Under `verdict` the engine stops the guest at the
    # first marker it recognises, which is `make smoke`'s behaviour and all a
    # row needs when everything it asserts is printed by then. Under `window`
    # the guest has to outlive that marker, so its serial port is redirected
    # into the row's log: the engine's own capture then never sees a marker,
    # its deadline becomes the length of the run, and its timeout verdict is
    # this row's normal outcome. Either way the engine owns the QEMU process
    # and reaps it.
    engine_log="$log"
    if [ "$mode" = "window" ]; then
        case $log in
            *" "*) setup_error "row '$id': a windowed log path cannot contain spaces" ;;
        esac
        row_flags="$row_flags -serial file:$log"
        engine_log="$work/monitor-$id.txt"
        : > "$log"
    elif [ "$mode" != "verdict" ]; then
        setup_error "row '$id' has an unknown mode '$mode'"
    fi

    QEMU_FLAGS="$row_flags" MEM="$row_mem" INITRD_MODE="$initrd" \
    OUT="$OUT" LOG="$engine_log" TIMEOUT="$timeout" \
        sh "$ENGINE" > "$engine_out" 2>&1
    engine_rc=$?

    [ "$engine_rc" = 3 ] && {
        printf 'setup error\n'
        cat "$engine_out" >&2
        exit 3
    }

    # The markers decide, not the engine's exit code: a row that boots and then
    # prints something forbidden has failed, and dtb-squeeze's failing engine is
    # the whole point of that row.
    #
    # Each check reports its offender through a file rather than a command
    # substitution, so the checks run in this shell: a substitution is a
    # subshell, and a setup error raised inside one would exit that subshell and
    # be downgraded to an ordinary row failure on the way out.
    detail=
    verdict=passed
    message=
    if ! check_required "$log" "$required" > "$work/msg.txt"; then
        verdict=failed
        message="missing required marker '$(cat "$work/msg.txt")' (engine rc $engine_rc)"
    elif ! check_forbidden "$log" "$forbidden" > "$work/msg.txt"; then
        verdict=failed
        message="forbidden marker '$(cat "$work/msg.txt")' present"
    elif ! run_post "$post" "$log" "$post_out" > "$work/msg.txt"; then
        verdict=failed
        message="post-check $post: $(cat "$work/msg.txt")"
        detail="$post_out"
    fi
    [ -n "$detail" ] || detail="$log"

    # A windowed row's log is the serial capture only, so the engine's view of
    # the same run is appended once the checks are done: its verdict, and the
    # tail it prints of QEMU's own output, which is where a machine that never
    # started says why. One artifact per row that way, and appending after the
    # checks keeps it out of what they read.
    if [ "$mode" = "window" ]; then
        {
            printf '\n---- %s ----\n' "$ENGINE"
            cat "$engine_out"
        } >> "$log"
    fi

    elapsed=$(($(date +%s) - row_started))

    case $expect in
        pass|skip-if:*)
            if [ "$verdict" = passed ]; then
                passed=$((passed + 1))
                printf 'passed  [%ss]\n' "$elapsed"
                emit_case "$id" passed '' "$elapsed" ''
            else
                failed=$((failed + 1))
                printf 'FAILED: %s  [%ss]\n' "$message" "$elapsed"
                printf 'scenarios:%s: %s\n' "$id" "$message" >> "$failures"
                emit_case "$id" failed "$message" "$elapsed" "$detail"
            fi
            ;;
        xfail:*)
            reason="${expect#xfail:}"
            if [ "$verdict" = passed ]; then
                failed=$((failed + 1))
                printf 'XPASS: expected to fail (%s)  [%ss]\n' "$reason" "$elapsed"
                printf 'scenarios:%s: unexpectedly passed, expected failure: %s\n' \
                       "$id" "$reason" >> "$failures"
                emit_case "$id" failed "unexpectedly passed, expected failure: $reason" \
                          "$elapsed" "$log"
            else
                xfailed=$((xfailed + 1))
                printf 'expected failure: %s  [%ss]\n' "$message" "$elapsed"
                emit_case "$id" expected-fail "$reason ($message)" "$elapsed" ''
            fi
            ;;
        *)
            setup_error "row '$id' has an unknown expectation '$expect'"
            ;;
    esac
done 3< "$SCENARIOS"

[ "$selected" -gt 0 ] || setup_error "no row matched '$FILTER'"

total=$(($(date +%s) - run_started))
write_report "$total"

if [ -s "$failures" ]; then
    echo '===> Failures'
    cat "$failures"
fi

echo '===> Summary'
printf 'Serial logs:  %s/scenario-<id>.log\n' "$OUT"
printf 'Results file: %s\n' "$REPORT"
printf 'Total rows:      %s\n' "$selected"
printf '  passed:        %s\n' "$passed"
printf '  failed:        %s\n' "$failed"
printf '  expected-fail: %s\n' "$xfailed"
printf '  skipped:       %s\n' "$skipped"
printf 'Total time: %ss\n' "$total"

[ "$failed" -eq 0 ] || exit 1
exit 0
