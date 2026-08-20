#!/usr/bin/env python3
"""Boot the emulated Duet 3 MB6HC, send G-code to it, and print what it says back.

Drives Renode headlessly. G-code goes in by writing characters straight into the emulated USART2
rather than through a socket terminal: it is deterministic, it needs no ports, and the emulation stays
paused between steps so timing is reproducible. Replies are recovered by watching writes to the USART2
transmit holding register.

Usage: run_gcode.py "M115" "M114" ...
       run_gcode.py --settle 2.0 --after 1.0 "G1 X10 F600"
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.dirname(HERE)

USART2_THR = 0x4002C01C
DEFAULT_RENODE = "/private/tmp/claude-501/-Users-smetrot-work-duet3/6ff76603-8eea-43a1-8021-d3914bb2166d/scratchpad/Renode.app/Contents/MacOS"


def build_script(args, firmware, elf):
    lines = [
        f'include @{EMU}/peripherals/SAME70_TimerCounter.cs',
        f'include @{EMU}/peripherals/SAME70_ParallelIO.cs',
        'mach create "duet3_mb6hc"',
        f'machine LoadPlatformDescription @{EMU}/platforms/duet3_mb6hc.repl',
        f'sysbus LoadBinary @{firmware} 0x400000',
        f'sysbus LoadSymbolsFrom @{elf}',
        'cpu VectorTableOffset 0x400000',
        'cpu PC `sysbus ReadDoubleWord 0x400004`',
        'cpu SP `sysbus ReadDoubleWord 0x400000`',
        f'sysbus AddWatchpointHook {USART2_THR:#x} 4 Write "print \'TX %d\' % value"',
        'logLevel 3',
    ]
    if args.trace_steps:
        # The PIO model logs traced edges at Info with the emulated timestamp; everything else stays quiet.
        lines.append('logLevel 1 pioc')
    lines += [
        f'emulation RunFor "{args.settle}"',
    ]
    for command in args.gcode:
        lines.append(f'echo "SENT {command}"')
        for ch in command + "\n":
            lines.append(f'usart2 WriteChar {ord(ch):#x}')
        lines.append(f'emulation RunFor "{args.after}"')
    lines += [
        'echo "STEP EDGES"',
        'pioc EdgeCount',
        'echo "STEP CLOCK"',
        'tc0 StepClock',
        'quit',
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('gcode', nargs='*', help='G-code lines to send, in order')
    parser.add_argument('--settle', default='2.0', help='emulated seconds to boot before sending anything')
    parser.add_argument('--after', default='1.0', help='emulated seconds to run after each line')
    parser.add_argument('--renode', default=os.environ.get('RENODE_DIR', DEFAULT_RENODE))
    parser.add_argument('--firmware', default=os.environ.get('DUET_FW'),
                        help='CRC-appended USE_EMBEDDED_FILES .bin')
    parser.add_argument('--elf', default=os.environ.get('DUET_ELF'))
    parser.add_argument('--raw', action='store_true', help='also print the raw Renode output')
    parser.add_argument('--trace-steps', action='store_true', help='log every step-pin edge with its emulated timestamp')
    parser.add_argument('--edge-log', help='write parsed edges to this file as "microseconds pin level"')
    args = parser.parse_args()

    if not args.firmware or not args.elf:
        raise SystemExit("set --firmware and --elf (or DUET_FW / DUET_ELF)")

    script = build_script(args, args.firmware, args.elf)
    with tempfile.NamedTemporaryFile('w', suffix='.resc', delete=False) as handle:
        handle.write(script)
        script_path = handle.name

    try:
        result = subprocess.run([os.path.join(args.renode, 'renode'), '--disable-xwt', '--console',
                                 '-e', f'include @{script_path}'],
                                capture_output=True, text=True, timeout=3600)
    finally:
        os.unlink(script_path)

    if args.raw:
        print(result.stdout)

    if args.edge_log:
        edges = re.findall(r'pioc:\s+([\d.]+) pin (\d+) -> (\d)', result.stdout)
        with open(args.edge_log, 'w') as handle:
            for micros, pin, level in edges:
                handle.write(f"{micros} {pin} {level}\n")
        print(f"--- wrote {len(edges)} edges to {args.edge_log}")

    # Interleave what we sent with what came back, decoding TX bytes into text.
    pending = bytearray()
    label = None
    for line in result.stdout.splitlines():
        sent = re.match(r'^SENT (.*)$', line.strip())
        tx = re.match(r'^TX (\d+)$', line.strip())
        if sent:
            flush(pending)
            print(f">>> {sent.group(1)}")
        elif tx:
            pending.append(int(tx.group(1)) & 0xFF)
        elif line.strip() in ('STEP EDGES', 'STEP CLOCK'):
            flush(pending)
            label = line.strip().lower()
        elif re.match(r'^0x[0-9a-fA-F]+$', line.strip()) and label:
            print(f"--- {label}: {int(line.strip(), 16)}")
            label = None
    flush(pending)


def flush(pending):
    if pending:
        text = pending.decode('ascii', errors='replace')
        for out_line in text.splitlines():
            print(f"    {out_line}")
        pending.clear()


if __name__ == '__main__':
    main()
