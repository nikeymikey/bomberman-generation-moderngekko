#!/usr/bin/env python3
"""
parse_minidump.py -- identify the faulting module in a Windows minidump.

Reads only the two streams that matter for "where did it crash":
  ExceptionStream  (6) -- exception code and faulting address
  ModuleListStream (4) -- loaded modules with base addresses and sizes

Then maps the faulting address into whichever module contains it. No symbols
required: naming the module is usually enough to decide who is at fault.
"""
import argparse, struct, sys

EXCEPTION_NAMES = {
    0xC0000005: 'ACCESS_VIOLATION',
    0xC000041D: 'FATAL_USER_CALLBACK_EXCEPTION',
    0xC00000FD: 'STACK_OVERFLOW',
    0xC0000374: 'HEAP_CORRUPTION',
    0xC000001D: 'ILLEGAL_INSTRUCTION',
    0x80000003: 'BREAKPOINT',
}
AV_KIND = {0: 'read from', 1: 'write to', 8: 'execute'}

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]

def read_mdstring(b, rva):
    length = u32(b, rva)                      # length in BYTES, excluding NUL
    return b[rva + 4: rva + 4 + length].decode('utf-16-le', 'replace')

def main():
    ap = argparse.ArgumentParser(description='Identify the faulting module in a minidump')
    ap.add_argument('dump')
    a = ap.parse_args()
    b = open(a.dump, 'rb').read()

    if b[:4] != b'MDMP':
        raise SystemExit('Not a minidump (missing MDMP signature)')

    n_streams  = u32(b, 8)
    dir_rva    = u32(b, 12)
    streams = {}
    for i in range(n_streams):
        off = dir_rva + i * 12
        streams[u32(b, off)] = (u32(b, off + 4), u32(b, off + 8))   # (size, rva)

    print(f'minidump: {a.dump}')
    print(f'streams : {n_streams}')

    fault_addr = None
    if 6 in streams:                                   # ExceptionStream
        _, rva = streams[6]
        rec = rva + 8                                  # skip ThreadId + alignment
        code   = u32(b, rec + 0)
        addr   = u64(b, rec + 16)
        nparam = u32(b, rec + 24)
        params = [u64(b, rec + 32 + 8 * i) for i in range(min(nparam, 15))]
        fault_addr = addr
        name = EXCEPTION_NAMES.get(code, '')
        print()
        print('=== EXCEPTION ===')
        print(f'  code    : 0x{code:08X}  {name}')
        print(f'  address : 0x{addr:016X}')
        if code == 0xC0000005 and len(params) >= 2:
            kind = AV_KIND.get(params[0], f'op={params[0]}')
            print(f'  detail  : attempted to {kind} 0x{params[1]:016X}')
            if params[1] < 0x10000:
                print('            (near-null -- dereferencing a freed/never-set pointer)')
    else:
        print('  no exception stream')

    if 4 not in streams:
        raise SystemExit('no module list stream')
    _, rva = streams[4]
    count = u32(b, rva)
    mods = []
    for i in range(count):
        m = rva + 4 + i * 108
        base = u64(b, m)
        size = u32(b, m + 8)
        name = read_mdstring(b, u32(b, m + 20))
        mods.append((base, size, name))

    print()
    print(f'=== MODULES ({count}) ===')
    if fault_addr is not None:
        hit = [m for m in mods if m[0] <= fault_addr < m[0] + m[1]]
        if hit:
            base, size, name = hit[0]
            print(f'  FAULTING MODULE: {name}')
            print(f'    base   : 0x{base:016X}  size: 0x{size:X}')
            print(f'    offset : +0x{fault_addr - base:X}')
        else:
            print('  faulting address is not inside any loaded module')
            print('  (freed memory, a stale function pointer, or a dynamic stub)')
    keys = ('moderngekko', 'recomp', 'vulkan', 'opengl', 'sdl', 'dolphin',
            'ntdll', 'kernel32', 'kernelbase', 'nv', 'amd', 'atio', 'ig')
    picked = [(b_, s_, n_) for b_, s_, n_ in sorted(mods)
              if any(k in n_.split('\\')[-1].lower() for k in keys)]
    print()
    if picked:
        print('  loaded modules of interest:')
        for base, size, name in picked:
            print(f'    0x{base:016X} +0x{size:<8X} {name.split(chr(92))[-1]}')
    else:
        print('  all loaded modules:')
        for base, size, name in sorted(mods):
            print(f'    0x{base:016X} +0x{size:<8X} {name.split(chr(92))[-1]}')

if __name__ == '__main__':
    main()
