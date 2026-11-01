#!/bin/sh
#
# check-loader-hook.sh
# ReixOS
#
# The loader-death request belongs only to the diagnostic image. Inspect both
# the linked ELF and the stripped copy that is packed into the initrd.
# Usage: BOOT_MODE=standard OUT=.reix sh scripts/check-loader-hook.sh

set -eu

BOOT_MODE="${BOOT_MODE:-standard}"

case "$BOOT_MODE" in
    diagnostic) exit 0 ;;
    standard|verbose) ;;
    *) echo "SETUP: unknown BOOT_MODE '$BOOT_MODE'" >&2; exit 3 ;;
esac

for app in ProcessServer Init; do
    for path in "${OUT:-.reix}/$app.elf" "${OUT:-.reix}/stripped/$app.elf"; do
        if [ ! -s "$path" ]; then
            echo "SETUP: missing ELF ($path)" >&2
            exit 3
        fi
        if LC_ALL=C grep -aqF 'Shell.die' "$path"; then
            echo "FAIL: loader-death name Shell.die in $path ($BOOT_MODE)" >&2
            exit 1
        else
            result=$?
            if [ "$result" -ne 1 ]; then
                echo "SETUP: could not inspect $path" >&2
                exit 3
            fi
        fi
    done
done

echo "PASS: loader-death name absent from $BOOT_MODE ProcessServer and Init ELFs"
