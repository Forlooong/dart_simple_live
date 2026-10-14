"""Fail packaging when required native assets or architectures are missing."""

import argparse
import ctypes
from pathlib import Path
import struct
import subprocess
import zipfile


LIBRARIES = ("danmaku_native", "dart_quickjs")
ANDROID_ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")


def elf_load_alignments(data):
    if data[:4] != b"\x7fELF" or data[5] not in (1, 2):
        raise ValueError("Native asset is not a supported ELF binary")
    endian = "<" if data[5] == 1 else ">"
    if data[4] == 1:
        offset = struct.unpack_from(endian + "I", data, 28)[0]
        size, count = struct.unpack_from(endian + "HH", data, 42)
        alignment_offset, alignment_format = 28, "I"
    elif data[4] == 2:
        offset = struct.unpack_from(endian + "Q", data, 32)[0]
        size, count = struct.unpack_from(endian + "HH", data, 54)
        alignment_offset, alignment_format = 48, "Q"
    else:
        raise ValueError("Unsupported ELF class")
    alignments = []
    for index in range(count):
        header = offset + index * size
        if struct.unpack_from(endian + "I", data, header)[0] == 1:
            alignments.append(struct.unpack_from(
                endian + alignment_format, data, header + alignment_offset)[0])
    if not alignments:
        raise ValueError("Native ELF asset has no loadable segments")
    return alignments


def verify_android(directory):
    for abi in ANDROID_ABIS:
        apk = directory / f"app-{abi}-release.apk"
        with zipfile.ZipFile(apk) as archive:
            for library in LIBRARIES:
                candidates = [name for name in archive.namelist()
                              if name.startswith(f"lib/{abi}/")
                              and library in Path(name).name
                              and name.endswith(".so")]
                if len(candidates) != 1:
                    raise ValueError(f"{apk.name}: expected one {library} for {abi}")
                data = archive.read(candidates[0])
                if min(elf_load_alignments(data)) < 16384:
                    raise ValueError(f"{apk.name}: {library} is not 16 KiB aligned")
                print(f"Verified {apk.name}: {candidates[0]} (16 KiB load alignment)")


def verify_directory(directory, platform):
    suffixes = {"windows": (".dll",), "linux": (".so",),
                "macos": (".dylib", ""), "ios": (".dylib", ""),
                "cli": (".dll", ".so", ".dylib")}[platform]
    for library in LIBRARIES:
        candidates = [path for path in directory.rglob("*")
                      if path.is_file() and library in path.name
                      and path.suffix in suffixes]
        if not candidates:
            raise ValueError(f"{directory}: missing native library {library}")
        for path in candidates:
            if platform in ("macos", "ios"):
                architectures = ["arm64", "x86_64"] if platform == "macos" else ["arm64"]
                subprocess.run(["lipo", str(path), "-verify_arch", *architectures], check=True)
            if platform in ("windows", "linux", "macos", "cli"):
                native = ctypes.CDLL(str(path.resolve()))
                if library == "danmaku_native":
                    native.dm_abi_version.restype = ctypes.c_uint32
                    if native.dm_abi_version() != 1:
                        raise ValueError(f"{path}: native ABI is not version 1")
                else:
                    native.sl_regex_create.restype = ctypes.c_void_p
                    native.sl_regex_destroy.argtypes = [ctypes.c_void_p]
                    handle = native.sl_regex_create()
                    if not handle:
                        raise ValueError(f"{path}: controlled regex runtime failed to load")
                    native.sl_regex_destroy(handle)
            print(f"Verified native asset: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("android", "ios", "macos", "linux", "windows", "cli"))
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    if not args.directory.is_dir():
        raise ValueError(f"Bundle directory does not exist: {args.directory}")
    if args.platform == "android":
        verify_android(args.directory)
    else:
        verify_directory(args.directory, args.platform)


if __name__ == "__main__":
    main()
