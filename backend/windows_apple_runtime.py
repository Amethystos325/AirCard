r"""Process-local CoreFP registration for the experimental x64 Store runtime.

Store iTunes keeps LibraryPath in its package registry. AirTrafficHost loaded by
an unpackaged Python worker cannot see it. Redirect ONLY that DLL's lookup of
HKLM\Software\Apple Inc.\CoreFP to a private hive containing the installed DLL
path. All other registry calls and Apple's authentication code run unchanged.
No system/user registry keys, installed DLLs, or executable code are modified.
"""
from __future__ import annotations

import ctypes as C
import tempfile
from pathlib import Path


def is_corefp_lookup(root: int, path: str | bytes | None) -> bool:
    if isinstance(path, bytes):
        path = path.decode("ascii", "replace")
    return (root is not None and root & 0xFFFFFFFF == 0x80000002
            and isinstance(path, str)
            and path.casefold() == "software\\apple inc.\\corefp")


class CoreFPRegistration:
    """Scoped import-table adapter; use only in the disposable native worker."""

    def __init__(self, runtime: Path, module):
        self.runtime = runtime.resolve()
        self.module = module  # Keep the library loaded until hooks are removed.
        self.patches = []
        self.hive = C.c_void_p()
        self.directory = None

    def __enter__(self):
        import pefile
        import winreg

        corefp = self.runtime / "CoreFP.dll"
        if not corefp.is_file():
            raise RuntimeError("The installed Apple runtime is missing CoreFP.dll")
        self.kernel = C.WinDLL("kernel32", use_last_error=True)
        self.protect = self.kernel.VirtualProtect
        self.protect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
        self.protect.restype = C.c_int
        advapi = C.WinDLL("advapi32", use_last_error=True)
        load = advapi.RegLoadAppKeyW
        load.argtypes = [C.c_wchar_p, C.POINTER(C.c_void_p), C.c_uint32, C.c_uint32, C.c_uint32]
        load.restype = C.c_long
        self.close_key = advapi.RegCloseKey
        self.close_key.argtypes = [C.c_void_p]
        self.close_key.restype = C.c_long
        try:
            self.directory = tempfile.TemporaryDirectory(prefix="corefp-", dir=self.runtime.parent)
            status = load(str(Path(self.directory.name) / "runtime.dat"),
                          C.byref(self.hive), winreg.KEY_ALL_ACCESS, 1, 0)
            if status:
                raise OSError(status, "Could not create private CoreFP registry hive")
            with winreg.CreateKeyEx(self.hive.value, "CoreFP", 0, winreg.KEY_ALL_ACCESS) as key:
                winreg.SetValueEx(key, "LibraryPath", 0, winreg.REG_SZ, str(corefp))
            with pefile.PE(str(self.runtime / "AirTrafficHost.dll")) as pe:
                if pe.FILE_HEADER.Machine != 0x8664 or C.sizeof(C.c_void_p) != 8:
                    raise RuntimeError("CoreFP adapter requires the x64 Apple runtime and Python")
                imports = {item.name: self.module._handle + item.address - pe.OPTIONAL_HEADER.ImageBase
                           for group in pe.DIRECTORY_ENTRY_IMPORT
                           if group.dll.lower() == b"advapi32.dll" for item in group.imports}
            for suffix, string_type in (("A", C.c_char_p), ("W", C.c_wchar_p)):
                name = ("RegOpenKeyEx" + suffix).encode()
                if name not in imports:
                    raise RuntimeError("Unsupported AirTrafficHost registry imports")
                self._redirect(imports[name], string_type, b"CoreFP" if suffix == "A" else "CoreFP")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _write_pointer(self, address, value):
        old = C.c_uint32()
        if not self.protect(address, C.sizeof(C.c_void_p), 4, C.byref(old)):
            raise C.WinError(C.get_last_error())
        C.c_void_p.from_address(address).value = value
        previous = C.c_uint32()
        if not self.protect(address, C.sizeof(C.c_void_p), old.value, C.byref(previous)):
            raise C.WinError(C.get_last_error())

    def _redirect(self, address, string_type, private_path):
        prototype = C.WINFUNCTYPE(C.c_long, C.c_void_p, string_type,
                                 C.c_uint32, C.c_uint32, C.c_void_p, use_last_error=True)
        original_address = C.c_void_p.from_address(address).value
        original = prototype(original_address)

        def lookup(root, path, options, access, result):
            if is_corefp_lookup(root, path):
                return original(self.hive.value, private_path, options, access, result)
            return original(root, path, options, access, result)

        callback = prototype(lookup)
        self.patches.append((address, original_address, callback))
        self._write_pointer(address, C.cast(callback, C.c_void_p).value)

    def __exit__(self, *args):
        for address, original, callback in reversed(self.patches):
            self._write_pointer(address, original)
        self.patches.clear()
        if self.hive.value:
            status = self.close_key(self.hive)
            if status:
                raise OSError(status, "Could not close private CoreFP hive")
            self.hive.value = None
        if self.directory:
            self.directory.cleanup()
            self.directory = None
