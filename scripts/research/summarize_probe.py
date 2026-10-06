#!/usr/bin/env python3
"""Summarize local probe traffic without printing text, image, or library payloads."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import statistics
import struct


def unpack_seven_bit(data):
    accumulator = bits = 0
    output = bytearray()
    for byte in data:
        if byte > 127:
            raise ValueError('non-seven-bit payload')
        accumulator |= byte << bits
        bits += 7
        while bits >= 8:
            output.append(accumulator & 255)
            accumulator >>= 8
            bits -= 8
    return bytes(output)


def varint(data, index):
    value = 0
    for shift in range(0, 70, 7):
        if index >= len(data):
            raise ValueError('truncated varint')
        byte = data[index]
        index += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, index
    raise ValueError('oversized varint')


def fields(data):
    index = 0
    result = []
    while index < len(data):
        tag, index = varint(data, index)
        number, wire = tag >> 3, tag & 7
        if number == 0:
            raise ValueError('invalid field zero')
        if wire == 0:
            value, index = varint(data, index)
        elif wire in (1, 2, 5):
            if wire == 2:
                size, index = varint(data, index)
            else:
                size = 8 if wire == 1 else 4
            if size > len(data) - index:
                raise ValueError('truncated field')
            value = data[index:index + size]
            index += size
        else:
            raise ValueError('unsupported wire type')
        result.append((number, wire, value))
    return result


def summarize(path):
    counts = Counter()
    values = defaultdict(list)
    times = []
    rejected = 0
    complete = 0
    for line in path.open():
        record = json.loads(line)
        if record.get('kind') != 'sysex':
            continue
        complete += 1
        try:
            frame = bytes.fromhex(record['hex'])
            # Only the single-packet envelope observed in the captures is established.
            if not frame.startswith(bytes.fromhex('f0 70 00 00 01 00')) or not frame.endswith(b'\xf7'):
                raise ValueError('unrecognized envelope')
            message = fields(unpack_seven_bit(frame[6:-1]))
            if len(message) != 1 or message[0][1] != 2:
                raise ValueError('unrecognized message structure')
            number, _, body = message[0]
            counts[number] += 1
            if number != 51:
                continue
            decoded = {}
            for field, wire, value in fields(body):
                if field in (2, 3, 4) and wire == 1:
                    numeric = struct.unpack('<d', value)[0]
                    if not math.isfinite(numeric):
                        raise ValueError('nonfinite realtime value')
                    decoded[field] = numeric
            for field in (2, 3):
                if field in decoded:
                    values[field].append(decoded[field])
            times.append(float(record['elapsed_seconds']))
        except (ValueError, KeyError, TypeError):
            rejected += 1
    result = {'complete_sysex': complete, 'top_level_field_counts': dict(sorted(counts.items())),
              'unrecognized_or_invalid_frames': rejected,
              'privacy': 'Text, images, library entries, identifiers and absolute sender timestamps omitted.'}
    for field, label in [(2, 'normalized_playhead'), (3, 'playback_rate')]:
        data = values[field]
        if data:
            result[label] = {'count': len(data), 'min': min(data), 'max': max(data),
                             'value_changes': sum(a != b for a, b in zip(data, data[1:]))}
    if values[2]:
        jumps = [b - a for a, b in zip(values[2], values[2][1:])]
        if jumps:
            result['largest_normalized_position_step'] = max(jumps, key=abs)
    if len(times) > 1:
        gaps = [b - a for a, b in zip(times, times[1:])]
        result['realtime_interval_seconds'] = {'median': statistics.median(gaps), 'min': min(gaps), 'max': max(gaps)}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('traffic', type=Path, help='Private traffic.ndjson outside Git')
    args = parser.parse_args()
    print(json.dumps(summarize(args.traffic), indent=2, sort_keys=True))
