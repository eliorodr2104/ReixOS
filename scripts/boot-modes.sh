#!/bin/sh
#
# boot-modes.sh
# ReixOS
#
# Builds and boots all three BOOT_MODE profiles and checks each one printed what
# its own contract says and nothing the other two own. The three images differ
# only in presentation, so the one thing all three are asked for is the same:
# the shell prompt. Reaching it is what says a quiet boot is a boot and not a
# boot that stopped early.
#
# The contracts, which are `BootMode` in ReixABI said in grep:
#
#   standard    the banner, then the shell. No subsystem line, no milestone.
#   verbose     the banner, then five macro phases in order, and no subsystem.
#   diagnostic  the banner, every subsystem, and no milestone.
#
# Lines that report trouble are nobody's contract: they are printed in every
# mode, which is why none of them appears below as something to refuse. The one
# fault a healthy boot used to carry, the NX check jumping into a data page, is
# gone from two of the three modes because the check no longer runs there, not
# because the kernel stopped reporting faults.
#
# Two cross builds more than `make test` already does, so this is its own target
# rather than part of it: `vm-test` covers the diagnostic image on every run.
#
# Inputs, all overridable so this and the Makefile agree on one set:
#   MAKE        make binary                 (default: make)
#   QEMU        QEMU binary                 (default: qemu-system-aarch64)
#   QEMU_FLAGS  machine/cpu/disk flags      (default: matches the Makefile)
#   OUT         build output directory      (default: .reix)
#   DISK        disk image to provision and boot (default: the Makefile's)
#   TIMEOUT     seconds to wait for a shell (default: 40)
#
# Exit codes: 0 all three hold, 1 a contract was broken, 2 a boot never reached
# the shell, 3 a build failed.

set -u

MAKE="${MAKE:-make}"
QEMU="${QEMU:-qemu-system-aarch64}"
QEMU_FLAGS="${QEMU_FLAGS:--machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic}"
OUT="${OUT:-.reix}"
DISK="${DISK:-}"
TIMEOUT="${TIMEOUT:-40}"

# The image goes on the disk `make` provisions and the guest boots the one in
# QEMU_FLAGS. They have to be the same file, so an override reaches both.
disk_argument=""
if [ -n "$DISK" ]; then
    disk_argument="DISK=$DISK"
fi

# The one line every mode owes, and the marker that ends each run. It is the
# shell's greeting rather than a server's, because a server's is exactly what
# two of the three modes are not allowed to print.
PROMPT='ReixOS shell. Type Shell.help() to see what this understands.'

failures=0
log=

# Fails the run, naming the mode and what was wrong with it.
fault() {
    echo "FAIL [$1] $2" >&2
    failures=$((failures + 1))
}

require() {
    grep -qF -- "$2" "$log" || fault "$1" "missing '$2'"
}

refuse() {
    if grep -qF -- "$2" "$log"; then
        fault "$1" "printed '$2', which is not this mode's to print"
    fi
}

# Each marker has to appear on a line after the one that satisfied the previous
# marker, so this is order and not merely presence.
require_order() {
    ro_mode=$1
    shift
    ro_prev=0
    for ro_marker in "$@"; do
        ro_line=$(grep -nF -- "$ro_marker" "$log" 2>/dev/null \
                  | awk -F: -v min="$ro_prev" '$1 > min { print $1; exit }')
        if [ -z "$ro_line" ]; then
            fault "$ro_mode" "'$ro_marker' is missing or out of order"
            return
        fi
        ro_prev=$ro_line
    done
}

for mode in standard verbose diagnostic; do
    echo "== $mode =="

    # shellcheck disable=SC2086 # an empty override has to vanish, not become ""
    if ! "$MAKE" programs BOOT_MODE="$mode" $disk_argument \
         >"$OUT/boot-mode-$mode.build.log" 2>&1; then
        echo "SETUP: the $mode image would not build, see $OUT/boot-mode-$mode.build.log" >&2
        exit 3
    fi

    log="$OUT/boot-mode-$mode.log"
    QEMU="$QEMU" QEMU_FLAGS="$QEMU_FLAGS" OUT="$OUT" LOG="$log" \
        TIMEOUT="$TIMEOUT" SUCCESS_MARKER="$PROMPT" \
        scripts/smoke.sh >/dev/null || {
            echo "FAIL [$mode] never reached the shell, see $log" >&2
            exit 2
        }

    # Every mode: the banner, the shell, and no panic.
    require "$mode" '[ reix ] ReixOS'
    require "$mode" "$PROMPT"
    refuse  "$mode" 'REIX-PANIC'
    refuse  "$mode" '[ PANIC ]'

    case $mode in
        standard)
            refuse "$mode" '[ BOOT  ]'
            refuse "$mode" 'memory online'
            refuse "$mode" '[ INIT  ] Hi, this is init process!'
            refuse "$mode" '[ SERVE ] Console Server running'
            refuse "$mode" '[ SERVE ] VT Adapter running'
            refuse "$mode" '[ DISK  ] serving '
            refuse "$mode" '[ FS    ] mounted, '
            refuse "$mode" 'PROFILE DUMP'
            refuse "$mode" '[ CHECK ]'
            refuse "$mode" 'access=fetch'
            ;;

        verbose)
            require_order "$mode" \
                'memory online' 'devices online' 'processes online' \
                'userland started' 'session ready'
            refuse "$mode" '[ BOOT  ][PPM ]'
            refuse "$mode" '[ INIT  ] Hi, this is init process!'
            refuse "$mode" '[ SERVE ] VT Adapter running'
            refuse "$mode" '[ DISK  ] serving '
            refuse "$mode" 'PROFILE DUMP'
            refuse "$mode" '[ CHECK ]'
            refuse "$mode" 'access=fetch'
            ;;

        diagnostic)
            require_order "$mode" \
                '[PPM ] Physical Page Manager ready.' \
                '[VMM ] Virtual Memory Manager ready.' \
                '[HEAP] Kernel heap ready.' \
                '[GIC ] Generic Interrupt Controller ready.' \
                '[FS  ] Internal File System ready.' \
                '[PROC] Process Manager ready.' \
                '[SCHD] Scheduler ready.' \
                '[IPC ] IPC ready.' \
                '[SYS ] Syscall Handler ready.' \
                '[TIM ] Virtual Timer enabled.' \
                '[KERN] Kernel is running.' \
                'Handing control to user space.' \
                '[ INIT  ] Hi, this is init process!' \
                '[ SERVE ] VT Adapter running'
            refuse "$mode" 'memory online'
            refuse "$mode" 'session ready'
            require "$mode" '[ CHECK ] storage stack whole, nothing leaked'
            ;;
    esac
done

if [ "$failures" -ne 0 ]; then
    echo "FAIL: $failures boot mode contract(s) broken" >&2
    exit 1
fi

echo "PASS: standard, verbose and diagnostic each printed their own boot"
