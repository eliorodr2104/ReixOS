#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/reix-profile-authority.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

cat > "$work/engine.sh" <<'EOF'
#!/bin/sh
cat "$PROFILE_FIXTURE" > "$LOG"
EOF

cat > "$work/init.log" <<'EOF'
[ INIT  ] ProcessServer endpoint ready
[ INIT  ] Shell.elf reached Ready
EOF
cat > "$work/shell.log" <<'EOF'
[ TERMINAL BASELINE ] system status=measured
[ TERMINAL BASELINE ] process status=measured mapped_semantics=address-space-nonunique pid=7 name=Shell.elf mapped_pages=1
[ TERMINAL BASELINE ] process status=measured mapped_semantics=address-space-nonunique pid=6 name=ProcessServer.el mapped_pages=1
[TRACE] t=1 ev=interactionMark pid=7 sequence=1
[ SHELL ] this shell is done
EOF

verdict() {
    expected=$1
    label=$2
    status=0
    TERMINAL_PROFILE=1 SCENARIOS="$root/Tests/Scenarios/scenarios.tsv" \
    ENGINE="$work/engine.sh" OUT="$work/out" PROFILE_FIXTURE="$work/run.log" \
        sh "$root/scripts/test/scenarios.sh" profile-authority > "$work/result.txt" 2>&1 || status=$?
    if [ "$status" -ne "$expected" ]; then
        printf '%s: expected exit %s, got %s\n' "$label" "$expected" "$status" >&2
        cat "$work/result.txt" >&2
        exit 1
    fi
}

cat "$work/shell.log" "$work/init.log" > "$work/run.log"
verdict 0 'Shell output before Init Ready'
cat "$work/init.log" "$work/shell.log" > "$work/run.log"
verdict 0 'Init Ready before Shell output'

cp "$work/run.log" "$work/complete.log"
for marker in 'ProcessServer endpoint ready' 'Shell.elf reached Ready' \
              'system status=measured' 'name=Shell.elf' 'name=ProcessServer.el' \
              'ev=interactionMark' 'this shell is done'; do
    grep -vF "$marker" "$work/complete.log" > "$work/run.log"
    verdict 1 "missing $marker"
done
sed 's/ev=interactionMark pid=7 /ev=interactionMark pid=6 /' \
    "$work/complete.log" > "$work/run.log"
verdict 1 'mark belongs to ProcessServer'
sed 's/name=Shell.elf mapped_pages=/name=Shell.elf missing_pages=/' \
    "$work/complete.log" > "$work/run.log"
verdict 1 'Shell mapped pages missing'
cat "$work/shell.log" > "$work/run.log"
sed '1h; 1d; 2G' "$work/init.log" >> "$work/run.log"
verdict 1 'Init reports reversed'
for identity in Shell.elf ProcessServer.el; do
    cat "$work/complete.log" > "$work/run.log"
    grep -F "name=$identity " "$work/complete.log" >> "$work/run.log"
    verdict 1 "duplicate $identity identity"
done

echo 'profile authority marker ordering: passed (2 orders, 12 refusals)'
