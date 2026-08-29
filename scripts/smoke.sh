#!/bin/sh
#
# smoke.sh
# ReixOS
#
# Boots the kernel image headless in QEMU and watches the serial log for a
# known-good or known-bad line, instead of a human watching `make run`.
#
# There is no GNU `timeout` on macOS, so the deadline is our own: QEMU runs
# in the background, we poll the log file, and a trap guarantees it is
# killed on every exit path (pass, fail, timeout, or a stray signal) so a
# failed run never leaves a QEMU process hogging the machine.
#
# Exit codes: 0 pass, 1 fail (bad marker or QEMU exited early), 2 timeout,
# 3 setup error (missing binary/image, nothing was booted).
#
# All inputs are overridable so the Makefile and a developer's shell agree
# on one set of defaults:
#   QEMU        QEMU binary                (default: qemu-system-aarch64)
#   QEMU_FLAGS  machine/cpu flags           (default: matches the Makefile)
#   MEM         guest RAM, e.g. 4M          (default: empty, machine default)
#   OUT         build output directory      (default: .reix)
#   KERNEL      kernel image                (default: $OUT/kernel.bin)
#   INITRD      initrd image                (default: $OUT/initrd.tar)
#   INITRD_MODE qemu | embedded             (default: qemu)
#   LOG         serial capture file         (default: $OUT/smoke.log)
#   TIMEOUT     seconds to wait for a verdict (default: 30)
#   SUCCESS_MARKER  the line that ends the run (default: the VT adapter's).
#               Override it to watch for something printed later than that.
#   INPUT       bytes to type at the guest's serial port, expanded by
#               `printf %b` so `\n` is a newline (default: empty, nothing typed)

set -u

QEMU="${QEMU:-qemu-system-aarch64}"
# `pmu=on` is required, not a preference: the kernel enables PMUv3 at boot and
# every PMU system register traps as undefined without it. Keep in sync with
# QEMU_FLAGS in the Makefile, which is what `make smoke` passes in here.
QEMU_FLAGS="${QEMU_FLAGS:--machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic}"
MEM="${MEM:-}"
OUT="${OUT:-.reix}"
KERNEL="${KERNEL:-$OUT/kernel.bin}"
INITRD="${INITRD:-$OUT/initrd.tar}"
# `embedded` boots without -initrd and leaves the kernel with the copy linked
# into kernel.bin, which is what gets QEMU past a 4 MiB machine. See the Makefile.
INITRD_MODE="${INITRD_MODE:-qemu}"
LOG="${LOG:-$OUT/smoke.log}"
TIMEOUT="${TIMEOUT:-30}"
INPUT="${INPUT:-}"
POLL_INTERVAL=0.5

# The lines a boot can end on. The VT adapter prints the first after the input
# and presentation path is live. A panic always opens with the banner below.
SUCCESS_MARKER="${SUCCESS_MARKER:-[ SERVE ] VT Adapter running}"
FAIL_REGEX='REIX-PANIC'

qemu_pid=

# Runs on every exit path (normal or signalled) so no run can leave a QEMU
# process behind. TERM first, KILL only if it ignores that within 2s.
cleanup() {
    trap '' EXIT INT TERM
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null
        tries=0
        while [ "$tries" -lt 10 ] && kill -0 "$qemu_pid" 2>/dev/null; do
            sleep 0.2
            tries=$((tries + 1))
        done
        kill -9 "$qemu_pid" 2>/dev/null
    fi
    wait "$qemu_pid" 2>/dev/null
}
trap cleanup EXIT INT TERM

if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "SETUP: '$QEMU' not found on PATH" >&2
    exit 3
fi
if [ ! -f "$KERNEL" ]; then
    echo "SETUP: missing image ($KERNEL) - run 'make image' first" >&2
    exit 3
fi

# Only the qemu mode needs the file on disk; embedded reads it out of $KERNEL.
initrd_args=""
if [ "$INITRD_MODE" != "embedded" ]; then
    if [ ! -f "$INITRD" ]; then
        echo "SETUP: missing image ($INITRD) - run 'make image' first" >&2
        exit 3
    fi
    initrd_args="-initrd $INITRD"
fi

mem_args=""
if [ -n "$MEM" ]; then
    mem_args="-m $MEM"
fi

mkdir -p "$(dirname "$LOG")"
: > "$LOG"

# Synthetic serial input: `-nographic` puts the guest's UART on our stdin, so a
# file there is a typist. Nothing has to be timed, because QEMU pushes only what
# the receive FIFO will take and holds the rest. SerialServer drains that FIFO
# before waiting on the interrupt, preserving bytes received during boot.
#
# Which is only true while the UART is on stdio. A run that redirects it (the
# matrix's `window` mode does, with `-serial file:`) would swallow the input
# whole, and a probe that types nothing is a probe that proves nothing, so that
# combination is refused rather than run.
stdin_file=/dev/null
if [ -n "$INPUT" ]; then
    case $QEMU_FLAGS in
        *-serial*)
            echo "SETUP: INPUT needs the guest's serial port on stdin, and" \
                 "QEMU_FLAGS redirects it" >&2
            exit 3
            ;;
    esac

    stdin_file="$LOG.input"
    printf '%b' "$INPUT" > "$stdin_file"
fi

# shellcheck disable=SC2086 # QEMU_FLAGS and the two arg strings are deliberately
# unquoted word lists; an empty one has to vanish rather than become "".
"$QEMU" $QEMU_FLAGS $mem_args -kernel "$KERNEL" $initrd_args <"$stdin_file" >"$LOG" 2>&1 &
qemu_pid=$!

start_ts=$(date +%s)
result=timeout

while :; do
    # -F: the marker's brackets are literal text, not a regex class.
    if grep -qF "$SUCCESS_MARKER" "$LOG" 2>/dev/null; then
        result=pass
        break
    fi
    if grep -Eq "$FAIL_REGEX" "$LOG" 2>/dev/null; then
        result=fail
        break
    fi
    # QEMU exiting on its own, before either marker showed up, is itself a
    # failure (crash, missing device, immediate abort).
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        result=fail
        break
    fi

    now=$(date +%s)
    if [ $((now - start_ts)) -ge "$TIMEOUT" ]; then
        result=timeout
        break
    fi
    sleep "$POLL_INTERVAL"
done

elapsed=$(($(date +%s) - start_ts))

case "$result" in
    pass)
        echo "PASS: boot smoke test succeeded in ${elapsed}s"
        exit 0
        ;;
    fail)
        echo "FAIL: boot smoke test failed after ${elapsed}s"
        echo "---- last 20 lines of $LOG ----"
        tail -n 20 "$LOG" 2>/dev/null
        exit 1
        ;;
    timeout)
        echo "TIMEOUT: no verdict within ${TIMEOUT}s"
        echo "---- last 20 lines of $LOG ----"
        tail -n 20 "$LOG" 2>/dev/null
        exit 2
        ;;
esac
