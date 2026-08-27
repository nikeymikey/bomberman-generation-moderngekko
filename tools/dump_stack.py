#!/usr/bin/env python3
"""
dump_stack.py -- recover a plausible call chain from a minidump's crashing thread.

No symbol server and no PDB required. Reads the crashing thread's stack memory
out of the dump, scans it for 8-byte values that land inside the faulting
module, and resolves each to the nearest preceding function symbol from an
`nm` listing of the executable.

This is a scan, not a true unwind: stale frames and data that merely looks like
a code address will appear. Names make that obvious, and the real chain is
usually the readable spine running down the list.
"""
import argparse, struct

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u64(b, o): return struct.unpack_from('<Q', b, o)[0]

def read_mdstring(b, rva):
    n = u32(b, rva)
    return b[rva + 4: rva + 4 + n].decode('utf-16-le', 'replace')

def load_symbols(path):
    syms = []
    for line in open(path, errors='replace'):
        p = line.split(None, 2)
        if len(p) < 3 or p[1].lower() not in ('t', 'w'):
            continue
        try:
            syms.append((int(p[0], 16), p[2].rstrip()))
        except ValueError:
            pass
    syms.sort()
    return syms

def resolve(syms, va):
    lo, hi = 0, len(syms)
    while lo < hi:
        mid = (lo + hi) // 2
        if syms[mid][0] <= va: lo = mid + 1
        else: hi = mid
    if lo == 0: return None
    addr, name = syms[lo - 1]
    return name, va - addr

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('dump')
    ap.add_argument('--syms', required=True, help='output of: nm -C --defined-only <exe>')
    ap.add_argument('--module', required=True, help='module basename to attribute frames to')
    ap.add_argument('--imagebase', required=True, help='linked ImageBase from objdump -f, e.g. 0x140000000')
    ap.add_argument('--max', type=int, default=60)
    a = ap.parse_args()

    linked_base = int(a.imagebase, 16)
    b = open(a.dump, 'rb').read()
    if b[:4] != b'MDMP':
        raise SystemExit('not a minidump')

    n, dir_rva = u32(b, 8), u32(b, 12)
    streams = {}
    for i in range(n):
        o = dir_rva + i * 12
        streams[u32(b, o)] = (u32(b, o + 4), u32(b, o + 8))

    if 6 not in streams: raise SystemExit('no exception stream')
    _, rva = streams[6]
    crash_tid = u32(b, rva)
    fault_pc = u64(b, rva + 8 + 16)

    if 4 not in streams: raise SystemExit('no module list')
    _, mrva = streams[4]
    load_base = load_size = None
    for i in range(u32(b, mrva)):
        m = mrva + 4 + i * 108
        name = read_mdstring(b, u32(b, m + 20)).split('\\')[-1].lower()
        if name == a.module.lower():
            load_base, load_size = u64(b, m), u32(b, m + 8)
    if load_base is None:
        raise SystemExit(f'module {a.module} not in the dump module list')
    slide = load_base - linked_base

    if 3 not in streams: raise SystemExit('no thread list')
    _, trva = streams[3]
    stack = None
    ctx = None
    for i in range(u32(b, trva)):
        t = trva + 4 + i * 48
        if u32(b, t) != crash_tid:
            continue
        # MINIDUMP_THREAD: ThreadId 0, SuspendCount 4, PriorityClass 8,
        # Priority 12, Teb 16, Stack{Start 24, {DataSize 32, Rva 36}},
        # ThreadContext{DataSize 40, Rva 44}. Reading Teb as the stack base
        # is an easy slip and yields nonsense sizes -- these offsets are exact.
        stack_start = u64(b, t + 24)
        size, mem_rva = u32(b, t + 32), u32(b, t + 36)
        stack = (stack_start, b[mem_rva: mem_rva + size])
        ctx_rva = u32(b, t + 44)
        # CONTEXT_AMD64: Rsp at 0x98, Rbp at 0xA0, Rip at 0xF8.
        ctx = (u64(b, ctx_rva + 0x98), u64(b, ctx_rva + 0xA0), u64(b, ctx_rva + 0xF8))
    if stack is None or not stack[1]:
        raise SystemExit('crashing thread has no captured stack memory')

    syms = load_symbols(a.syms)
    start, mem = stack
    print(f'crashing thread : {crash_tid}')
    print(f'faulting pc     : 0x{fault_pc:016X}')
    r = resolve(syms, fault_pc - slide)
    if r: print(f'                  {r[0]} +0x{r[1]:X}')
    print(f'stack           : 0x{start:016X} .. 0x{start + len(mem):016X}  ({len(mem)} bytes)')
    if ctx:
        print(f'rsp / rbp / rip : 0x{ctx[0]:016X}  0x{ctx[1]:016X}  0x{ctx[2]:016X}')
    print()
    print('=== code addresses found on the stack (innermost first) ===')
    shown = 0
    scan_from = 0
    if ctx and start <= ctx[0] < start + len(mem):
        scan_from = (ctx[0] - start) & ~7
    for off in range(scan_from, len(mem) - 8, 8):
        va = u64(mem, off)
        if not (load_base <= va < load_base + load_size):
            continue
        r = resolve(syms, va - slide)
        if not r:
            continue
        name, delta = r
        if delta > 0x20000:            # far past a symbol: probably not a return address
            continue
        print(f'  [sp+0x{off:06X}] 0x{va:016X}  {name} +0x{delta:X}')
        shown += 1
        if shown >= a.max:
            print('  ... (truncated)')
            break
    if shown == 0:
        print('  none -- the stack may have been unwound already')

if __name__ == '__main__':
    main()
