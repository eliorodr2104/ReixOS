#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/Tests/Fixtures/trace/interaction.log"
terminal_fixture="$root/Tests/Fixtures/trace/terminal-baseline.log"
terminal_manifest="$root/Tests/Fixtures/trace/terminal-baseline-manifest.json"
work=$(mktemp -d "${TMPDIR:-/tmp}/reix-trace-interaction.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

interaction="$work/interaction.txt"
exported="$work/interaction.json"

cd "$root"
"$root/reix" trace "$fixture" --interaction > "$interaction"
grep -Fx 'interaction groups=4 invalid=3' "$interaction"
expected_interaction='interaction correlation=1 serial_delivery_to_decoded=10.00us '
expected_interaction="${expected_interaction}"'decoded_to_shell=10.00us shell_to_editor=10.00us '
expected_interaction="${expected_interaction}"'editor_to_parser=10.00us editor_to_presentation=20.00us '
expected_interaction="${expected_interaction}"'presentation_to_console_ack=10.00us total=60.00us '
expected_interaction="${expected_interaction}"'rendered_bytes=12 full_estimate_bytes=100 '
expected_interaction="${expected_interaction}"'diff_estimate_bytes=20 render_plan=diff '
expected_interaction="${expected_interaction}"'wire_time_estimate=1041.67us '
expected_interaction="${expected_interaction}"'wire_provenance=estimated-115200-8n1 duplicate=0'
grep -Fx "$expected_interaction" "$interaction"
grep -F 'interaction correlation=2 serial_delivery_to_decoded=10.00us decoded_to_shell=unavailable' "$interaction"
grep -F 'interaction correlation=3 serial_delivery_to_decoded=unavailable' "$interaction"
grep -F 'interaction correlation=4 serial_delivery_to_decoded=unavailable' "$interaction" | grep -F 'duplicate=1'
# One chunk, several records: later records inherit the chunk's delivery mark,
# a record before any delivery or from another process does not.
chunked="$work/interaction-chunked.txt"
"$root/reix" trace "$root/Tests/Fixtures/trace/interaction-chunked.log" --interaction > "$chunked"
grep -Fx 'interaction groups=6 invalid=0' "$chunked"
grep -F 'interaction correlation=9 serial_delivery_to_decoded=unavailable' "$chunked"
grep -F 'interaction correlation=1 serial_delivery_to_decoded=10.00us' "$chunked" | grep -F 'total=20.00us'
grep -F 'interaction correlation=2 serial_delivery_to_decoded=100.00us' "$chunked" | grep -F 'total=150.00us'
grep -F 'interaction correlation=3 serial_delivery_to_decoded=10.00us' "$chunked" | grep -F 'total=unavailable'
grep -F 'interaction correlation=4 serial_delivery_to_decoded=40.00us' "$chunked" | grep -F 'total=60.00us'
grep -F 'interaction correlation=5 serial_delivery_to_decoded=unavailable' "$chunked"
"$root/reix" trace "$fixture" --export "$exported"
python3 - "$exported" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))['traceEvents']
marks = [e for e in events if e.get('cat') == 'terminal']
assert any(e.get('ph') == 'i' and e.get('name') == 'serialDelivered'
           and e['args'] == {'correlation': 1, 'value': 0, 'valid': True} for e in marks)
assert any(e.get('ph') == 'i' and e.get('name') == 'interactionInvalid'
           and e['args'].get('valid') is False for e in marks)
PY

terminal_interaction="$work/terminal-interaction.txt"
terminal_json="$work/terminal-baseline.json"
"$root/reix" trace "$terminal_fixture" --interaction > "$terminal_interaction"
python3 "$root/scripts/terminal-baseline-report.py" \
    "$terminal_fixture" "$terminal_interaction" "$terminal_manifest" "$terminal_json"
python3 - "$terminal_json" <<'PY'
import json, math, sys
document = json.load(open(sys.argv[1]))
assert document['schema_version'] == 2
assert document['workload']['id'] == 'mixed-terminal-storage'
assert document['workload']['storage'] == 'virtio-blk-rxfs-storagecheck-shell'
assert document['workload']['pre_shell_workload'] == 'StorageCheck'
assert document['guest_memory_bytes'] == 4_194_304
assert document['build_mode'] == 'instrumented'
system = document['system']
assert system['physical_total_pages']['value'] == 1024
assert system['physical_allocated_pages']['value'] == 512
assert system['physical_free_pages']['value'] == 512
assert system['kernel_heap_live_capacity_bytes']['value'] == 10000
assert system['kernel_heap_reserved_bytes']['value'] == 16384
assert system['user_heap_virtual_reservation_bytes']['value'] == 65536
assert system['exception_stack_used_high_water_bytes']['value'] == 0
assert system['exception_stack_capacity_bytes']['value'] == 4096
assert system['pmu']['status'] == 'available'
assert system['pmu']['instructions_retired']['status'] == 'unavailable'
assert system['pmu']['instructions_retired']['reason'] == 'inst-retired-not-advertised'
assert system['trace_lost_final_snapshot']['scope'] == 'bounded-ring-cumulative-at-final-dump'
assert document['editor_workloads']['paste-8192']['cycles']['value'] == 500
assert document['editor_workloads']['paste-8192']['instructions']['status'] == 'unavailable'
assert document['editor_workloads']['paste-8192']['duration_ticks']['value'] == 200
assert document['editor_workloads']['paste-8192']['duration_us']['value'] == 200.0
processes = document['processes']
assert processes['SerialServer']['mapped_pages']['value'] == 9
assert processes['Shell']['stack_extent_pages']['value'] == 10
assert processes['Shell']['stack_capacity_pages']['value'] == 32
interactions = document['interactions']
assert interactions['groups'] == 3 and interactions['invalid'] == 0
assert interactions['latencies']['total']['p50_us'] == 70.0
assert interactions['latencies']['total']['p95_us'] == 100.0
assert math.isclose(interactions['wire_time_us']['p50_us'], 16 * 10_000_000 / 115200)
assert document['provenance']['binary_and_input']['toolchain'] == 'fixture'
PY

# Build one valid PMU-off fixture and a corpus that must fail closed.
python3 - "$terminal_fixture" "$terminal_manifest" "$terminal_interaction" "$work" <<'PY'
import json, pathlib, re, sys
serial = pathlib.Path(sys.argv[1]).read_text()
manifest = json.loads(pathlib.Path(sys.argv[2]).read_text())
interaction = pathlib.Path(sys.argv[3]).read_text()
out = pathlib.Path(sys.argv[4])
def emit(name, text): (out / name).write_text(text)
emit('missing-process.log', '\n'.join(x for x in serial.splitlines() if 'name=VTAdapter.elf' not in x) + '\n')
emit('missing-field.log', serial.replace(' kernel_heap_live_capacity_bytes=10000', '', 1))
emit('malformed-field.log', serial.replace('physical_total_pages=1024', 'physical_total_pages=NaN', 1))
system = next(x for x in serial.splitlines() if x.startswith('[ TERMINAL BASELINE ] system '))
emit('duplicate-system.log', serial + system + '\n')
emit('contradictory-system.log', serial + '[ TERMINAL BASELINE ] system status=unavailable reason=late-failure\n')
# A record printed with a version tag comes from an image whose records this
# reporter does not know, so it has to be refused rather than parsed around.
emit('stale-schema-token.log', serial.replace('system status=measured', 'system status=measured schema=2', 1))
emit('lost-trace.log', serial.replace('trace_lost=0', 'trace_lost=1', 1))
emit('dump-lost.log', serial.replace('[TRACE] begin v=2 freq=1000000 lost=0',
                                     '[TRACE] begin v=2 freq=1000000 lost=1', 1))
emit('trace-drop.log', serial.replace('[TRACE] end count=20',
                                      '[TRACE-DROP] omitted=1\n[TRACE] end count=20', 1))
emit('trace-count-mismatch.log', serial.replace('[TRACE] end count=20',
                                                '[TRACE] end count=19', 1))
emit('truncated-trace.log', serial + '[TRACE] begin v=2 freq=1000000 lost=0 stack=0 exstack=0\n')
emit('nested-trace.log', serial.replace('[TRACE] end count=20', '[TRACE] begin v=2 freq=1000000 lost=0 stack=0 exstack=0\n[TRACE] end count=20', 1))
emit('invalid-interaction.txt', interaction.replace('interaction groups=3 invalid=0', 'interaction groups=3 invalid=1', 1))
emit('missing-total.txt', re.sub(r'total=[^ ]+', 'total=unavailable', interaction))
off = re.sub(r' pmu_status=available counter_unit=raw cycles=[0-9]+ instruction_event_status=unavailable instruction_reason=[^ \n]+',
             ' pmu_status=unavailable reason=pmu-counters-unavailable', serial)
off = re.sub(r' pmu_status=available pmu_event_counters=[0-9]+ instruction_event_status=(?:available|unavailable)(?: instruction_reason=[^ \n]+)?',
             ' pmu_status=unavailable pmu_reason=pmu-not-present', off)
emit('pmu-off.log', off)
manifest['pmu'] = 'off'
(manifest_cpu := manifest)['effective_cpu'] = 'cortex-a53,pmu=off'
manifest_cpu['qemu_flags'] = manifest_cpu['qemu_flags'].replace(
    'cortex-a53,pmu=on', 'cortex-a53,pmu=off'
)
(out / 'pmu-off-manifest.json').write_text(json.dumps(manifest, sort_keys=True) + '\n')
inst_lines = []
for line in serial.splitlines():
    if line.startswith('[ TERMINAL BASELINE ] editor '):
        line = line.replace(
            'instruction_event_status=unavailable instruction_reason=inst-retired-not-advertised',
            'instruction_event_status=available instructions=0'
        )
    elif line.startswith('[ TERMINAL BASELINE ] system '):
        line = line.replace(
            'instruction_event_status=unavailable instruction_reason=inst-retired-not-advertised',
            'instruction_event_status=available'
        )
    inst_lines.append(line)
inst = '\n'.join(inst_lines) + '\n'
emit('pmu-instruction-zero.log', inst)
emit('editor-event-mismatch.log', serial.replace(
    'instruction_event_status=unavailable instruction_reason=inst-retired-not-advertised',
    'instruction_event_status=available instructions=0', 1
))
emit('system-event-mismatch.log', serial.replace(
    'pmu_event_counters=6 instruction_event_status=unavailable instruction_reason=inst-retired-not-advertised',
    'pmu_event_counters=6 instruction_event_status=available', 1
))
emit('missing-instruction-reason.log', serial.replace(
    ' instruction_reason=inst-retired-not-advertised', '', 1
))
bad_manifest = dict(manifest); bad_manifest['schema_version'] = 9
(out / 'bad-manifest.json').write_text(json.dumps(bad_manifest) + '\n')
bad_cpu = dict(manifest); bad_cpu['effective_cpu'] = 'cortex-a72,pmu=off'
(out / 'bad-cpu-manifest.json').write_text(json.dumps(bad_cpu) + '\n')
bad_input = dict(manifest); bad_input['input_sha256'] = '0' * 64
(out / 'bad-input-manifest.json').write_text(json.dumps(bad_input) + '\n')
PY

python3 "$root/scripts/terminal-baseline-report.py" "$work/pmu-off.log" \
    "$terminal_interaction" "$work/pmu-off-manifest.json" "$work/pmu-off.json"
python3 - "$work/pmu-off.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['system']['pmu']['status'] == 'unavailable'
assert d['editor_workloads']['paste-8192']['duration_ticks']['status'] == 'measured'
assert d['editor_workloads']['paste-8192']['cycles']['status'] == 'unavailable'
PY
python3 "$root/scripts/terminal-baseline-report.py" "$work/pmu-instruction-zero.log" \
    "$terminal_interaction" "$terminal_manifest" "$work/pmu-instruction-zero.json"
python3 - "$work/pmu-instruction-zero.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
instructions = d['editor_workloads']['paste-8192']['instructions']
assert instructions['status'] == 'measured' and instructions['value'] == 0
PY

reject() {
    if python3 "$root/scripts/terminal-baseline-report.py" "$1" "$2" "$3" "$work/unexpected.json"; then
        echo "terminal baseline reporter accepted invalid fixture $1" >&2
        exit 1
    fi
}

for bad in missing-process missing-field malformed-field duplicate-system \
           contradictory-system stale-schema-token lost-trace dump-lost trace-drop trace-count-mismatch \
           truncated-trace nested-trace \
           editor-event-mismatch system-event-mismatch missing-instruction-reason
do
    reject "$work/$bad.log" "$terminal_interaction" "$terminal_manifest"
done
reject "$terminal_fixture" "$work/invalid-interaction.txt" "$terminal_manifest"
reject "$terminal_fixture" "$work/missing-total.txt" "$terminal_manifest"
reject "$terminal_fixture" "$terminal_interaction" "$work/bad-manifest.json"
reject "$terminal_fixture" "$terminal_interaction" "$work/bad-cpu-manifest.json"
reject "$terminal_fixture" "$terminal_interaction" "$work/bad-input-manifest.json"

echo 'trace interaction fixtures: passed'
