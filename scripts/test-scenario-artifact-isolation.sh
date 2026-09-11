#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/reix-scenario-isolation.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
out="$work/out"
mkdir -p "$out"
printf 'kernel' > "$out/kernel.bin"
printf 'disk' > "$out/disk.img"

cat > "$work/matrix.tsv" <<'EOF'
stale	4M	embedded	-	verdict	1	current-run-marker	-	run-manifest	pass
EOF
cat > "$work/engine.sh" <<'EOF'
#!/bin/sh
printf 'current run failed before its marker\n' > "$LOG"
exit 1
EOF
cat > "$work/swift" <<'EOF'
#!/bin/sh
echo 'Swift fixture'
EOF
cat > "$work/qemu" <<'EOF'
#!/bin/sh
echo 'QEMU fixture'
EOF
chmod +x "$work/engine.sh" "$work/swift" "$work/qemu"

stale="$out/scenario-stale.post-run-manifest.txt"
printf '{"stale":"would-have-passed"}\n' > "$stale"
set +e
SCENARIOS="$work/matrix.tsv" ENGINE="$work/engine.sh" OUT="$out" \
QEMU_FLAGS="-machine virt,gic-version=2 -cpu cortex-a53,pmu=on -nographic -drive file=$out/disk.img,if=none,format=raw,id=reixdisk -device virtio-blk-device,drive=reixdisk" \
SWIFT="$work/swift" QEMU="$work/qemu" DISK="$out/disk.img" \
    sh "$root/scripts/scenarios.sh" stale > "$work/result.txt" 2>&1
status=$?
set -e

[ "$status" -eq 1 ] || { cat "$work/result.txt"; exit 1; }
[ ! -e "$stale" ] || { echo 'stale post artifact survived the next run' >&2; exit 1; }
grep -F "missing required marker 'current-run-marker'" "$work/result.txt" >/dev/null
echo 'scenario artifact isolation: passed'
