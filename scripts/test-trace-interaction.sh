#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$root/Tests/Fixtures/trace/interaction.log"
terminal_fixture="$root/Tests/Fixtures/trace/terminal-baseline.log"
tracked_baseline="$root/Tests/Benchmarks/Baselines/terminal-4m.json"
work=$(mktemp -d "${TMPDIR:-/tmp}/reix-trace-interaction.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

swift_bin=${SWIFT:-swift}
interaction="$work/interaction.txt"
exported="$work/interaction.json"

cd "$root"
"$swift_bin" package --allow-writing-to-package-directory reix trace "$fixture" --interaction > "$interaction"
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
"$swift_bin" package --allow-writing-to-package-directory reix trace "$fixture" --export "$exported"
python3 - "$exported" <<'PY'
import json, sys
events = json.load(open(sys.argv[1]))['traceEvents']
marks = [e for e in events if e.get('cat') == 'terminal']
assert any(
    e.get('ph') == 'i'
    and e.get('name') == 'serialDelivered'
    and e['args'] == {'correlation': 1, 'value': 0, 'valid': True}
    for e in marks
)
assert any(e.get('ph') == 'i' and e.get('name') == 'interactionInvalid' and e['args'].get('valid') is False for e in marks)
PY

terminal_interaction="$work/terminal-interaction.txt"
terminal_json="$work/terminal-baseline.json"
"$swift_bin" package --allow-writing-to-package-directory reix trace "$terminal_fixture" --interaction > "$terminal_interaction"
python3 "$root/scripts/terminal-baseline-report.py" "$terminal_fixture" "$terminal_interaction" "$terminal_json"
python3 - "$terminal_json" <<'PY'
import json, math, sys

document = json.load(open(sys.argv[1]))
assert document['schema_version'] == 1
assert document['workload'] == {'command': 'shell.exit()', 'storage': 'absent'}
assert document['guest_memory_bytes'] == 4194304
assert document['initrd'] == 'embedded'
assert document['build_mode'] == 'REIX_TERMINAL_PROFILE'

system = document['system']
assert system['total_pages']['value'] == 1024
assert system['free_pages']['value'] == 512
assert system['free_bytes'] == {'status': 'derived', 'value': 2097152, 'provenance': 'pages-4096'}
assert system['counter_freq']['value'] == 1000000
assert system['trace_lost']['value'] == 0
assert system['trace_overflow_during_workload'] == {
    'status': 'measured',
    'value': 0,
    'provenance': 'trace-reset-before-workload',
}
assert system['kernel_stack_peak_bytes']['value'] == 1024
assert system['exception_stack_peak_bytes']['value'] == 0

processes = document['processes']
assert processes['SerialServer']['resident_pages']['value'] == 9
assert processes['SerialServer']['stack_pages']['value'] == 1
assert processes['ConsoleServer']['resident_pages']['value'] == 16
assert processes['ConsoleServer']['stack_pages']['value'] == 1
assert processes['InputServer']['resident_pages']['value'] == 12
assert processes['InputServer']['stack_pages']['value'] == 2
assert processes['Shell']['resident_pages']['value'] == 173
assert processes['Shell']['stack_pages']['value'] == 134
assert processes['VTAdapter']['resident_pages']['value'] == 19
assert processes['VTAdapter']['stack_pages']['value'] == 3

interactions = document['interactions']
assert interactions['groups'] == 3
assert interactions['invalid'] == 0
assert interactions['complete_total_samples'] == 3
assert interactions['latencies']['total']['samples'] == 3
assert interactions['latencies']['total']['unit'] == 'microseconds'
assert interactions['latencies']['total']['p50_us'] == 70.0
assert interactions['latencies']['total']['p95_us'] == 100.0
parser = interactions['latencies']['editor_to_parser']
assert parser['samples'] == 2
assert parser['unit'] == 'microseconds'
assert parser['p50_us'] == 10.0
assert parser['p95_us'] == 15.0
rendered = interactions['rendered_bytes']
assert rendered['status'] == 'measured'
assert rendered['unit'] == 'bytes'
assert rendered['provenance'] == 'console-acknowledged-rendered-byte-count'
assert rendered['p50_bytes'] == 16.0
assert rendered['p95_bytes'] == 20.0
wire = interactions['wire_time_us']
assert wire['status'] == 'derived'
assert wire['unit'] == 'microseconds'
assert wire['provenance'] == 'estimated-115200-8n1-frame-time'
assert math.isclose(wire['p50_us'], 16 * 10_000_000 / 115200)
assert math.isclose(wire['p95_us'], 20 * 10_000_000 / 115200)
PY

missing_process="$work/missing-process.log"
invalid_interaction="$work/invalid-interaction.txt"
missing_total="$work/missing-total.txt"
overflow_trace="$work/overflow-trace.log"
sed '/name=VTAdapter[^ ]*/d' "$terminal_fixture" > "$missing_process"
sed 's/^interaction groups=3 invalid=0$/interaction groups=3 invalid=1/' \
    "$terminal_interaction" > "$invalid_interaction"
sed -E 's/total=[^ ]+/total=unavailable/g' "$terminal_interaction" > "$missing_total"
sed 's/trace_lost=0/trace_lost=1/' "$terminal_fixture" > "$overflow_trace"

if python3 "$root/scripts/terminal-baseline-report.py" "$missing_process" "$terminal_interaction" "$work/unexpected.json"; then
    echo 'terminal baseline reporter accepted a missing VTAdapter process' >&2
    exit 1
fi
if python3 "$root/scripts/terminal-baseline-report.py" "$terminal_fixture" "$invalid_interaction" "$work/unexpected.json"; then
    echo 'terminal baseline reporter accepted invalid interactions' >&2
    exit 1
fi
if python3 "$root/scripts/terminal-baseline-report.py" "$terminal_fixture" "$missing_total" "$work/unexpected.json"; then
    echo 'terminal baseline reporter accepted no total samples' >&2
    exit 1
fi
if python3 "$root/scripts/terminal-baseline-report.py" "$overflow_trace" "$terminal_interaction" "$work/unexpected.json"; then
    echo 'terminal baseline reporter accepted lost trace events' >&2
    exit 1
fi

python3 - "$tracked_baseline" <<'PY'
import json, sys

document = json.load(open(sys.argv[1]))
assert document['schema_version'] == 1
assert document['guest_memory_bytes'] == 4_194_304
assert document['workload']['storage'] == 'absent'
interactions = document['interactions']
assert interactions['groups'] > 0
assert interactions['invalid'] == 0
assert interactions['complete_total_samples'] > 0
assert interactions['latencies']['total']['status'] == 'measured'
assert 'serial_delivery_to_decoded' in interactions['latencies']
assert 'presentation_to_console_ack' in interactions['latencies']
assert 'rendered_bytes' in interactions
assert 'uart_bytes' not in interactions
assert set(document['processes']) >= {
    'SerialServer',
    'ConsoleServer',
    'InputServer',
    'VTAdapter',
    'Shell',
}
assert document['system']['trace_overflow_during_workload'] == {
    'status': 'measured',
    'value': 0,
    'provenance': 'trace-reset-before-workload',
}
PY
