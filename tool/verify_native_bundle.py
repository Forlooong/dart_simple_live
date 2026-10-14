"""Fail packaging when required native assets or architectures are missing."""

import argparse
import ctypes
from pathlib import Path
import struct
import subprocess
import zipfile


LIBRARIES = ("danmaku_native", "dart_quickjs")
ANDROID_ABIS = ("armeabi-v7a", "arm64-v8a", "x86_64")


def elf_details(data):
    """Parse ELF program headers defensively; do not execute packaged code."""
    if len(data) < 16 or data[:4] != b"\x7fELF" or data[5] not in (1, 2):
        raise ValueError("Native asset is not a supported ELF binary")
    endian = "<" if data[5] == 1 else ">"
    bits = {1: 32, 2: 64}.get(data[4])
    header_size = 52 if bits == 32 else 64
    if bits is None or len(data) < header_size:
        raise ValueError("Unsupported or truncated ELF header")
    machine = struct.unpack_from(endian + "H", data, 18)[0]
    if bits == 32:
        offset = struct.unpack_from(endian + "I", data, 28)[0]
        size, count = struct.unpack_from(endian + "HH", data, 42)
        expected_size = 32
    else:
        offset = struct.unpack_from(endian + "Q", data, 32)[0]
        size, count = struct.unpack_from(endian + "HH", data, 54)
        expected_size = 56
    if (size != expected_size or count == 0 or count == 0xffff
            or offset < header_size or offset + size * count > len(data)):
        raise ValueError("Invalid ELF program header table")
    alignments = []
    for index in range(count):
        header = offset + index * size
        if bits == 32:
            kind, file_offset, address, _, file_size, memory_size, _, alignment = (
                struct.unpack_from(endian + "IIIIIIII", data, header))
        else:
            kind, _, file_offset, address, _, file_size, memory_size, alignment = (
                struct.unpack_from(endian + "IIQQQQQQ", data, header))
        if kind == 1:  # PT_LOAD
            if (alignment == 0 or alignment & (alignment - 1)
                    or file_offset % alignment != address % alignment
                    or file_size > memory_size or file_offset + file_size > len(data)):
                raise ValueError("Invalid ELF load segment bounds/alignment")
            alignments.append(alignment)
    if not alignments:
        raise ValueError("Native ELF asset has no loadable segments")
    return bits, machine, alignments


def elf_load_alignments(data):
    return elf_details(data)[2]


def zip_data_offset(stream, entry):
    stream.seek(entry.header_offset)
    header = stream.read(30)
    if len(header) != 30 or header[:4] != b"PK\x03\x04":
        raise ValueError("Invalid ZIP local header")
    name_size, extra_size = struct.unpack_from("<HH", header, 26)
    return entry.header_offset + 30 + name_size + extra_size


def verify_apk(apk, abi):
    expected_elf = {"armeabi-v7a": (32, 40), "arm64-v8a": (64, 183),
                    "x86_64": (64, 62)}[abi]
    with zipfile.ZipFile(apk) as archive, apk.open("rb") as stream:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError(f"{apk.name}: duplicate ZIP entries")
        libraries = [entry for entry in archive.infolist()
                     if entry.filename.startswith("lib/") and entry.filename.endswith(".so")]
        for library in LIBRARIES:
            candidates = [entry for entry in libraries
                          if library in Path(entry.filename).name]
            if len(candidates) != 1:
                raise ValueError(f"{apk.name}: expected one {library} for {abi}")
        for entry in libraries:
            parts = entry.filename.split("/")
            if len(parts) != 3 or parts[1] != abi:
                raise ValueError(f"{apk.name}: unexpected ABI/path {entry.filename}")
            bits, machine, alignments = elf_details(archive.read(entry))
            if (bits, machine) != expected_elf:
                raise ValueError(f"{apk.name}: wrong ELF architecture: {entry.filename}")
            # Android's 16 KiB requirement targets 64-bit devices. Our own
            # arm32 libraries also promise 16 KiB; third-party arm32 may use 4 KiB.
            own_library = any(library in parts[2] for library in LIBRARIES)
            minimum = 16384 if bits == 64 or own_library else 4096
            if min(alignments) < minimum:
                raise ValueError(f"{apk.name}: {entry.filename} load alignment < {minimum}")
            if entry.compress_type == zipfile.ZIP_STORED:
                # Match zipalign -P 16 for all stored shared objects.
                if zip_data_offset(stream, entry) % 16384:
                    raise ValueError(f"{apk.name}: {entry.filename} ZIP data is not 16 KiB aligned")
            elif entry.compress_type != zipfile.ZIP_DEFLATED:
                raise ValueError(f"{apk.name}: unsupported native ZIP compression")
            print(f"Verified {apk.name}: {entry.filename} (ELF ABI/alignment and ZIP storage)")


def verify_android(directory):
    for abi in ANDROID_ABIS:
        verify_apk(directory / f"app-{abi}-release.apk", abi)


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
