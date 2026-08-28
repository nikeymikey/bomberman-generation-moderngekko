#!/usr/bin/env python3
"""
merge_map.py -- merge real function names into a generated symbol map.

The generated map (find_functions.py) has complete address coverage but
placeholder fn_* names. A map from elsewhere -- Dolphin's Save Symbol Map after
a signature scan, or a Ghidra export -- has real names for some addresses and
usually misses others.

This keeps the union: a real name wins wherever one exists, the placeholder
stays everywhere else, and addresses only the other map knows about are added.

Both files are read with DolRecomp's own accepted forms, so a Dolphin
CodeWarrior map (`addr size addr align name`) and a plain `addr name` list both
work without conversion.
"""
import argparse
import re

# Names that carry no information, from whichever tool invented them.
#   fn_80084110    find_functions.py
#   zz_80084110_   Dolphin's PPCAnalyst::FindFunctions, applied before the
#                  signature database renames whatever it can match
#   FUN_80084110   Ghidra
# Treating one of these as a real name would overwrite a placeholder with a
# placeholder and quietly make the map look more identified than it is.
PLACEHOLDER = re.compile(r'^(fn|sub|func|FUN|zz)_[0-9A-Fa-f]{8}_?$', re.IGNORECASE)


def parse_line(line):
    """Return (address, name) or None, mirroring DolRecomp's symbol_map parser."""
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

    # CodeWarrior: startaddr size virtaddr [fileoffset] align name
    if len(parts) >= 6 and all(hexval(p) is not None for p in parts[:5]) and valid(parts[5]):
        return hexval(parts[2]), parts[5]
    if len(parts) >= 5 and all(hexval(p) is not None for p in parts[:4]) and valid(parts[4]):
        return hexval(parts[2]), parts[4]
    if len(parts) >= 3 and all(hexval(p) is not None for p in parts[:2]) and valid(parts[2]):
        return hexval(parts[0]), parts[2]
    if len(parts) >= 2 and hexval(parts[0]) is not None and valid(parts[1]):
        return hexval(parts[0]), parts[1]
    return None


def load(path):
    out = {}
    for line in open(path, errors='replace'):
        parsed = parse_line(line)
        if parsed and parsed[0] is not None:
            out.setdefault(parsed[0], parsed[1])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('base', help='the generated map with full coverage')
    ap.add_argument('overlay', nargs='+', help='maps carrying real names (Dolphin, Ghidra, hand-written)')
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('--keep-unknown', action='store_true',
                    help='also keep overlay addresses that are not in the base map')
    a = ap.parse_args()

    base = load(a.base)
    merged = dict(base)
    renamed = added = kept = skipped = dropped = 0

    for path in a.overlay:
        for address, name in load(path).items():
            if PLACEHOLDER.match(name):
                skipped += 1          # an overlay placeholder is not an improvement
                continue
            if address in merged:
                if PLACEHOLDER.match(merged[address]):
                    merged[address] = name
                    renamed += 1
                else:
                    kept += 1         # already named by hand or an earlier overlay: do not clobber
            elif a.keep_unknown:
                merged[address] = name
                added += 1
            else:
                dropped += 1      # a real name at an address the base map lacks

    named = sum(1 for n in merged.values() if not PLACEHOLDER.match(n))
    with open(a.output, 'w', newline='\n') as f:
        f.write(f'# merged from {a.base} + {", ".join(a.overlay)}\n')
        f.write('# Format: <hex address> <name>, one per line.\n')
        f.write(f'# {len(merged)} symbols, {named} named, {len(merged) - named} still placeholders.\n')
        for address in sorted(merged):
            f.write(f'{address:08X} {merged[address]}\n')

    print(f'base            : {len(base)} symbols')
    print(f'renamed         : {renamed}  (placeholder -> real name)')
    print(f'kept existing   : {kept}  (already had a real name)')
    print(f'added           : {added}')
    print(f'overlay skipped : {skipped}  (overlay name was itself a placeholder)')
    if dropped:
        print(f'DROPPED         : {dropped} real names at addresses the base map does not have.')
        print('                  The base map only knows direct bl targets; a function reached')
        print('                  only through a pointer is missing from it. Re-run with')
        print('                  --keep-unknown to keep these -- indirect calls still pass')
        print('                  through the dispatcher, so they are valid hook addresses.')
    print()
    print(f'wrote {a.output}: {len(merged)} symbols, {named} named '
          f'({100.0 * named / max(1, len(merged)):.1f}%)')


if __name__ == '__main__':
    main()
