#!/usr/bin/env python3
"""
apply_dol_patch.py -- apply a ModernGekko DOL patch manifest to a main.dol.

Same CSV format as MODERNGEKKO_DOL_PATCH_MANIFEST (`address,expected,replacement`,
big-endian hex words, virtual addresses, ascending, 4-byte aligned), so one file
serves both this build-time path and the runtime applier that ships to users.

Applied here rather than at startup because the recompiled module is cached
against the DOL's SHA-256: patching at launch would leave the runner executing a
module built from the unpatched DOL. Patch first, then rebuild the module.

Idempotent, like the upstream applier: a word already holding the replacement is
left alone. A word matching neither expected nor replacement is an error, not a
warning -- it means this is not the DOL the patch was written against.
"""
import argparse
import hashlib
import struct
import sys


def be32(data, offset):
    return struct.unpack_from('>I', data, offset)[0]


def text_sections(data):
    out = []
    for i in range(7):
        offset, address, size = be32(data, i * 4), be32(data, 0x48 + i * 4), be32(data, 0x90 + i * 4)
        if size:
            out.append((address, offset, size))
    return out


def load_manifest(path):
    patches = []
    previous = None
    with open(path) as handle:
        header = handle.readline().strip()
        if header != 'address,expected,replacement':
            raise SystemExit(f'{path}: first line must be "address,expected,replacement", got "{header}"')
        for number, line in enumerate(handle, start=2):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(',')
            if len(parts) != 3:
                raise SystemExit(f'{path}:{number}: expected three comma-separated fields')
            try:
                address, expected, replacement = (int(p, 16) for p in parts)
            except ValueError:
                raise SystemExit(f'{path}:{number}: fields must be hex')
            if address & 3:
                raise SystemExit(f'{path}:{number}: address 0x{address:08X} is not 4-byte aligned')
            if expected == replacement:
                raise SystemExit(f'{path}:{number}: expected and replacement are identical')
            if previous is not None and address <= previous:
                raise SystemExit(f'{path}:{number}: addresses must ascend')
            previous = address
            patches.append((address, expected, replacement))
    if not patches:
        raise SystemExit(f'{path}: no patches')
    return patches


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dol')
    ap.add_argument('manifest')
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    data = bytearray(open(a.dol, 'rb').read())
    if len(data) < 0x100:
        raise SystemExit('DOL header is truncated')
    sections = text_sections(data)
    before = hashlib.sha256(data).hexdigest()

    changed = 0
    already = 0
    for address, expected, replacement in load_manifest(a.manifest):
        mapped = [s for s in sections if s[0] <= address and address + 4 <= s[0] + s[2]]
        if len(mapped) != 1:
            raise SystemExit(f'0x{address:08X} maps to {len(mapped)} sections, expected exactly 1')
        base, offset, _ = mapped[0]
        position = offset + address - base
        actual = be32(data, position)
        if actual == replacement:
            print(f'  0x{address:08X}  already {replacement:08X}')
            already += 1
            continue
        if actual != expected:
            raise SystemExit(f'MISMATCH at 0x{address:08X}: expected {expected:08X}, found {actual:08X}\n'
                             'This is not the DOL this patch was written against. Nothing written.')
        struct.pack_into('>I', data, position, replacement)
        print(f'  0x{address:08X}  {expected:08X} -> {replacement:08X}')
        changed += 1

    print()
    print(f'sha256 before : {before}')
    if not changed:
        print(f'{already} patch(es) already applied; file untouched.')
        return
    if a.dry_run:
        print('dry run: nothing written.')
        return
    open(a.dol, 'wb').write(data)
    print(f'sha256 after  : {hashlib.sha256(data).hexdigest()}')
    print(f'{changed} patch(es) applied. The module cache is keyed on this hash, '
          'so rebuild the module next.')


if __name__ == '__main__':
    main()
