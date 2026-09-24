# -*- mode: python ; coding: utf-8 -*-
from pathlib import Path

root = Path.cwd()
a = Analysis(
    [str(root / 'backend/desktop_backend.py')],
    pathex=[str(root)],
    binaries=[],
    datas=[],
    hiddenimports=['pymobiledevice3.services.afc', 'pymobiledevice3.lockdown', 'pymobiledevice3.usbmux', 'pefile'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

# PyInstaller may collect macOS system frameworks through Python imports.
# Apple ships arm64e rather than arm64 slices for these private libraries.
# Keep the system copies in place instead of bundling them.
system_roots = ('/System/Library/', '/Library/Apple/System/Library/')
system_frameworks = {
    entry[0].split('/')[0]
    for entry in a.binaries
    if entry[1].startswith(system_roots) and '.framework/' in entry[0]
}
def keep(entry):
    destination = entry[0]
    if destination.split('/')[0] in system_frameworks:
        return False
    return not (entry[2] == 'SYMLINK' and any(name in entry[1] for name in system_frameworks))

a.binaries = [entry for entry in a.binaries if keep(entry)]
a.datas = [entry for entry in a.datas if keep(entry)]
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='aircard-backend', console=True)
coll = COLLECT(exe, a.binaries, a.datas, name='aircard-backend')
