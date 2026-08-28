#!/usr/bin/env python3
"""
check_imports.py -- verify a folder of Windows binaries is self-contained.

Reads the PE import directory of each executable and reports every DLL it needs
that is neither a Windows system DLL nor present in the folder.

Written because "no DLLs sit next to the executables" was mistaken for "the
executables need no DLLs". MinGW builds link against libgcc_s_seh-1.dll,
libstdc++-6.dll and libwinpthread-1.dll, which live in the compiler's bin
directory and are on a developer's PATH -- and on nobody else's.
"""
import argparse
import os
import struct
import sys

# Shipped by Windows. Anything outside this set has to travel with the release.
SYSTEM = {
    'kernel32.dll', 'user32.dll', 'gdi32.dll', 'advapi32.dll', 'shell32.dll',
    'ole32.dll', 'oleaut32.dll', 'shlwapi.dll', 'comdlg32.dll', 'comctl32.dll',
    'ws2_32.dll', 'wsock32.dll', 'iphlpapi.dll', 'crypt32.dll', 'secur32.dll',
    'bcrypt.dll', 'ncrypt.dll', 'wintrust.dll', 'version.dll', 'winmm.dll',
    'imm32.dll', 'setupapi.dll', 'cfgmgr32.dll', 'hid.dll', 'dwmapi.dll',
    'uxtheme.dll', 'userenv.dll', 'psapi.dll', 'dbghelp.dll', 'winhttp.dll',
    'wininet.dll', 'urlmon.dll', 'rpcrt4.dll', 'msvcrt.dll', 'ntdll.dll',
    'opengl32.dll', 'glu32.dll', 'gdiplus.dll', 'dnsapi.dll', 'mswsock.dll',
    'powrprof.dll', 'avrt.dll', 'mfplat.dll', 'dxgi.dll', 'd3d11.dll',
    'd3d12.dll', 'd3dcompiler_47.dll', 'xinput1_4.dll', 'xinput9_1_0.dll',
    'dinput8.dll', 'dsound.dll', 'winusb.dll', 'usp10.dll', 'oleacc.dll',
    'propsys.dll', 'shcore.dll', 'pdh.dll', 'netapi32.dll', 'authz.dll',
    # Ship with Windows despite the unusual names/extensions: bthprops is the
    # Bluetooth control panel (Wiimote support), qwave the QoS media API.
    'bthprops.cpl', 'qwave.dll', 'cabinet.dll', 'winspool.drv', 'msimg32.dll',
}
SYSTEM_PREFIXES = ('api-ms-win-', 'ext-ms-win-', 'vcruntime', 'msvcp', 'ucrtbase')


def imported_dlls(path):
    with open(path, 'rb') as handle:
        data = handle.read()
    if data[:2] != b'MZ':
        return None
    pe = struct.unpack_from('<I', data, 0x3C)[0]
    if data[pe:pe + 4] != b'PE\0\0':
        return None
    coff = pe + 4
    sections = struct.unpack_from('<H', data, coff + 2)[0]
    opt_size = struct.unpack_from('<H', data, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', data, opt)[0]
    # Data directories begin 0x60 into a PE32 optional header and 0x70 into a
    # PE32+ one, the difference being the wider BaseOfData/ImageBase fields.
    if magic == 0x10B:
        dirs = opt + 0x60      # PE32
    elif magic == 0x20B:
        dirs = opt + 0x70      # PE32+
    else:
        return None
    import_rva = struct.unpack_from('<I', data, dirs + 8)[0]
    if import_rva == 0:
        return []

    table = opt + opt_size
    layout = []
    for i in range(sections):
        entry = table + i * 40
        layout.append((struct.unpack_from('<I', data, entry + 12)[0],   # VirtualAddress
                       struct.unpack_from('<I', data, entry + 8)[0],    # VirtualSize
                       struct.unpack_from('<I', data, entry + 20)[0]))  # PointerToRawData

    def to_offset(rva):
        for va, size, raw in layout:
            if va <= rva < va + max(size, 1):
                return raw + (rva - va)
        return None

    names = []
    cursor = to_offset(import_rva)
    if cursor is None:
        return []
    while True:
        descriptor = data[cursor:cursor + 20]
        if len(descriptor) < 20 or descriptor == b'\0' * 20:
            break
        name_rva = struct.unpack_from('<I', descriptor, 12)[0]
        offset = to_offset(name_rva)
        if offset is not None:
            end = data.index(b'\0', offset)
            names.append(data[offset:end].decode('ascii', 'replace'))
        cursor += 20
    return names


def is_system(name):
    lowered = name.lower()
    return lowered in SYSTEM or lowered.startswith(SYSTEM_PREFIXES)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('folder')
    ap.add_argument('--list-missing', action='store_true',
                    help='print only the missing DLL names, one per line, for scripting')
    a = ap.parse_args()

    present = set()
    binaries = []
    for root, _, files in os.walk(a.folder):
        for name in files:
            lowered = name.lower()
            if lowered.endswith('.dll'):
                present.add(lowered)
            if lowered.endswith(('.exe', '.dll')):
                binaries.append(os.path.join(root, name))

    missing = {}
    unreadable = []
    for path in sorted(binaries):
        needs = imported_dlls(path)
        # Every real PE imports something. An empty list means the parse failed,
        # and reporting "self-contained" off the back of that would be worse
        # than reporting nothing.
        if needs is None or not needs:
            unreadable.append(os.path.relpath(path, a.folder))
            continue
        for dll in needs:
            if is_system(dll) or dll.lower() in present:
                continue
            missing.setdefault(dll, []).append(os.path.relpath(path, a.folder))

    if a.list_missing:
        # Silent on success so a caller can treat any output as work to do.
        for dll in sorted(missing):
            print(dll)
        return 1 if (missing or unreadable) else 0

    print(f'scanned {len(binaries)} binaries in {a.folder}')
    if unreadable:
        print()
        print('COULD NOT READ IMPORTS -- treat this as a failed check, not a pass:')
        for name in unreadable:
            print(f'  {name}')
        return 2
    if not missing:
        print('self-contained: every non-system import is present')
        return 0
    print()
    print('MISSING -- these must ship with the release:')
    for dll in sorted(missing):
        print(f'  {dll}')
        for who in missing[dll]:
            print(f'      needed by {who}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
