#!/usr/bin/env python3
"""
find_functions.py -- recover a function inventory from a GameCube main.dol.

Every `bl` in the recompiled output leaves the chunk with `ctx->pc = <target>`
and returns to the block dispatcher, which consults the mod manager. So a `bl`
target is, by construction, an address a mod can hook or patch reliably --
unlike an arbitrary address in the middle of a chunk, which is reached by a
plain `goto` and never passes through dispatch.

Reports each target with how many distinct call sites reference it, which is a
decent proxy for "is this a real, widely used function". Optionally writes the
result as a DolRecomp `--map` file (`<hex address> <name>` per line, which its
parser accepts), giving auto-generated names as a starting point for renaming.
"""
import argparse, struct
from collections import defaultdict

TEXT_MAX, DATA_MAX = 7, 11


def be32(b, o):
    return struct.unpack_from('>I', b, o)[0]


def dol_sections(b):
    """Yield (file_offset, load_address, size) for every non-empty text section."""
    out = []
    for i in range(TEXT_MAX):
        off = be32(b, 0x00 + i * 4)
        addr = be32(b, 0x48 + i * 4)
        size = be32(b, 0x90 + i * 4)
        if off and size:
            out.append((off, addr, size))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dol')
    ap.add_argument('--write-map', help='also write a DolRecomp --map file here')
    ap.add_argument('--prefix', default='fn', help='name prefix for generated symbols')
    ap.add_argument('--top', type=int, default=20, help='how many hot targets to print')
    a = ap.parse_args()

    b = open(a.dol, 'rb').read()
    entry = be32(b, 0xE0)
    sections = dol_sections(b)
    if not sections:
        raise SystemExit('no text sections -- is this really a DOL?')

    # Address ranges that actually hold code, so targets outside them can be
    # reported separately rather than silently trusted.
    ranges = [(addr, addr + size) for _, addr, size in sections]

    def in_text(x):
        return any(lo <= x < hi for lo, hi in ranges)

    callers = defaultdict(set)
    total_bl = 0
    for off, addr, size in sections:
        for i in range(0, size - 3, 4):
            word = be32(b, off + i)
            if (word >> 26) != 18:            # primary opcode 18 = b/ba/bl/bla
                continue
            aa, lk = (word >> 1) & 1, word & 1
            if lk != 1 or aa != 0:            # bl only: relative, link
                continue
            li = word & 0x03FFFFFC
            if li & 0x02000000:               # sign-extend the 26-bit displacement
                li -= 0x04000000
            site = addr + i
            callers[(site + li) & 0xFFFFFFFF].add(site)
            total_bl += 1

    targets = sorted(callers)
    inside = [t for t in targets if in_text(t)]
    outside = [t for t in targets if not in_text(t)]

    print(f'dol         : {a.dol}')
    print(f'entry point : 0x{entry:08X}')
    print(f'text        : ' + ', '.join(f'0x{lo:08X}-0x{hi:08X}' for lo, hi in ranges))
    print()
    print(f'bl instructions   : {total_bl}')
    print(f'distinct targets  : {len(targets)}')
    print(f'  inside .text    : {len(inside)}')
    print(f'  outside .text   : {len(outside)}  (thunks or bad decodes)')
    print()
    print(f'=== {a.top} most-referenced targets (by distinct call sites) ===')
    hot = sorted(inside, key=lambda t: (-len(callers[t]), t))[:a.top]
    for t in hot:
        print(f'  0x{t:08X}  {len(callers[t]):5d} call sites')

    if a.write_map:
        # One name per address, sorted, so the file stays readable and
        # hand-editable -- this is the file that accumulates real names over
        # time. The entry point is seeded first so it keeps its name even when
        # it is also a call target.
        names = {entry: '__entry'}
        for t in inside:
            names.setdefault(t, f'{a.prefix}_{t:08X}')
        with open(a.write_map, 'w', newline='\n') as f:
            f.write(f'# DolRecomp symbol map for {a.dol}\n')
            f.write('# Format: <hex address> <name>, one per line.\n')
            f.write('# Addresses are call targets recovered from every bl in the DOL.\n')
            f.write(f'# {len(names)} symbols; fn_* names are placeholders -- replace them as\n')
            f.write('# functions are identified. Do not renumber or reorder: the address is\n')
            f.write('# the identity, the name is just a label.\n')
            for address in sorted(names):
                f.write(f'{address:08X} {names[address]}\n')
        print()
        print(f'wrote map: {a.write_map}  ({len(names)} symbols)')


if __name__ == '__main__':
    main()
