#!/usr/bin/env python3
"""
whereis.py -- given a guest address, name the function that contains it.

Dolphin's debugger reports the address of an *instruction* (the store that
wrote a value, the PC at a breakpoint). A mod needs the address of the
*function* that instruction lives in, because that is what dispatch can
intercept. This maps one to the other using the symbol map.

    python tools/whereis.py symbols/GBGE5G.merged.map 0x80123456
"""
import argparse
import re
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0].rsplit('\\', 1)[0])

PLACEHOLDER = re.compile(r'^(fn|sub|func|FUN|zz)_[0-9A-Fa-f]{8}_?$', re.IGNORECASE)


def parse_line(line):
    text = line.split('//')[0].strip()
    if not text or text[0] in '#;':
        return None
    parts = text.split()

    def hexval(token):
        try:
            return int(token, 16)
        except ValueError:
            return None

    def valid(name):
        return name and name[0] not in '.*' and name not in ('UNUSED', '...UNUSED...')

    if len(parts) >= 6 and all(hexval(p) is not None for p in parts[:5]) and valid(parts[5]):
        return hexval(parts[2]), parts[5]
    if len(parts) >= 5 and all(hexval(p) is not None for p in parts[:4]) and valid(parts[4]):
        return hexval(parts[2]), parts[4]
    if len(parts) >= 3 and all(hexval(p) is not None for p in parts[:2]) and valid(parts[2]):
        return hexval(parts[0]), parts[2]
    if len(parts) >= 2 and hexval(parts[0]) is not None and valid(parts[1]):
        return hexval(parts[0]), parts[1]
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('map')
    ap.add_argument('address', nargs='+', help='guest addresses, hex, 0x optional')
    ap.add_argument('--context', type=int, default=2,
                    help='also show this many neighbouring symbols')
    a = ap.parse_args()

    symbols = []
    for line in open(a.map, errors='replace'):
        parsed = parse_line(line)
        if parsed:
            symbols.append(parsed)
    symbols.sort()
    if not symbols:
        raise SystemExit(f'no symbols parsed from {a.map}')

    for text in a.address:
        target = int(text, 16)
        lo, hi = 0, len(symbols)
        while lo < hi:
            mid = (lo + hi) // 2
            if symbols[mid][0] <= target:
                lo = mid + 1
            else:
                hi = mid
        index = lo - 1

        print(f'0x{target:08X}')

        # Reject non-code addresses before pretending to locate them. A PowerPC
        # instruction is always 4-byte aligned, and an address past the end of
        # the map by more than a function's worth is not in the code the map
        # covers -- typically heap, which is where game state lives.
        problems = []
        if target & 3:
            problems.append('not 4-byte aligned -- every PowerPC instruction is, '
                            'so this is a DATA address, not an instruction')
        if target > symbols[-1][0] + 0x1000:
            problems.append(f'past the last symbol (0x{symbols[-1][0]:08X}) by '
                            f'0x{target - symbols[-1][0]:X} -- outside the DOL\'s code')
        if problems:
            for problem in problems:
                print(f'  NOT CODE: {problem}')
            print('  Nothing in the symbol map contains this. If it came from a cheat')
            print('  search it is the variable itself; set a write breakpoint on it to')
            print('  get the instruction address instead.')
            print()
            continue

        if index < 0:
            print('  before the first symbol in the map')
            continue
        address, name = symbols[index]
        offset = target - address
        kind = 'placeholder' if PLACEHOLDER.match(name) else 'named'
        print(f'  in: {name}  ({kind})')
        print(f'      starts 0x{address:08X}, offset +0x{offset:X}')
        if index + 1 < len(symbols):
            print(f'      next symbol 0x{symbols[index + 1][0]:08X} '
                  f'({symbols[index + 1][0] - address} bytes after the start)')
        # A large offset usually means the containing function is missing from
        # the map -- worth knowing before hooking the symbol that precedes it.
        if offset > 0x800:
            print('      NOTE: large offset. The real function is probably absent from')
            print('            the map (reached only by pointer, so no bl targets it).')
            print('            Do not assume this symbol is the right hook target.')
        for step in range(1, a.context + 1):
            if index - step >= 0:
                prev_addr, prev_name = symbols[index - step]
                print(f'      -{step}: 0x{prev_addr:08X} {prev_name}')
        print()


if __name__ == '__main__':
    main()
