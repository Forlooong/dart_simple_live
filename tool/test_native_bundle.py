import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
import warnings
import zipfile

from verify_native_bundle import LIBRARIES, elf_load_alignments, verify_apk


def elf_fixture(bits=64, alignment=16384, machine=None):
    """A bounded PT_LOAD with a complete ELF/program header."""
    data = bytearray(128)
    data[:6] = b"\x7fELF" + bytes((1 if bits == 32 else 2, 1))
    struct.pack_into("<H", data, 18, machine or (40 if bits == 32 else 183))
    if bits == 32:
        struct.pack_into("<I", data, 28, 64)
        struct.pack_into("<HH", data, 42, 32, 1)
        struct.pack_into("<IIIIIIII", data, 64, 1, 0, 0, 0, 128, 128, 5, alignment)
    else:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0, 0, 128, 128, alignment)
    return data


class NativeBundleTest(unittest.TestCase):
    def test_read_both_elf_classes(self):
        self.assertEqual(elf_load_alignments(elf_fixture(32)), [16384])
        self.assertEqual(elf_load_alignments(elf_fixture(64, 65536)), [65536])

    def check_apk(self, extra=None, missing=False, stored=False, aligned=True,
                  abi="arm64-v8a", duplicate=False):
        with tempfile.TemporaryDirectory() as temp:
            apk = Path(temp) / "fixture.apk"
            bits = 32 if abi == "armeabi-v7a" else 64
            machine = 62 if abi == "x86_64" else None
            entries = [(f"lib/{abi}/lib{name}.so", elf_fixture(bits, machine=machine))
                       for name in LIBRARIES if not (missing and name == "dart_quickjs")]
            if extra:
                entries.append(extra)
            if duplicate:
                entries.append(entries[0])
            with zipfile.ZipFile(apk, "w") as archive, warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                for name, data in entries:
                    entry = zipfile.ZipInfo(name)
                    entry.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
                    if stored and aligned:
                        padding = (-(archive.fp.tell() + 30 + len(name.encode()) + 4)) % 16384
                        entry.extra = struct.pack("<HH", 0xffff, padding) + bytes(padding)
                    archive.writestr(entry, data)
            with contextlib.redirect_stdout(io.StringIO()):
                verify_apk(apk, abi)

    def test_all_architectures_and_compression_modes(self):
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            for stored in (False, True):
                with self.subTest(abi=abi, stored=stored):
                    self.check_apk(abi=abi, stored=stored)

    def test_missing_required_library(self):
        with self.assertRaisesRegex(ValueError, "expected one"):
            self.check_apk(missing=True)

    def test_checks_third_party_libraries(self):
        for data in (elf_fixture(alignment=4096), b"not ELF", elf_fixture(machine=62)):
            with self.subTest(data=data[:8]), self.assertRaises(ValueError):
                self.check_apk(extra=("lib/arm64-v8a/libthird_party.so", data))

    def test_arm32_third_party_4k_is_supported(self):
        self.check_apk(abi="armeabi-v7a", extra=(
            "lib/armeabi-v7a/libthird_party.so", elf_fixture(32, 4096)))

    def test_wrong_abi_directory(self):
        with self.assertRaisesRegex(ValueError, "unexpected ABI"):
            self.check_apk(extra=("lib/x86_64/libthird_party.so", elf_fixture(machine=62)))

    def test_duplicate_zip_entries(self):
        with self.assertRaisesRegex(ValueError, "duplicate ZIP"):
            self.check_apk(duplicate=True)

    def test_unaligned_stored_library(self):
        with self.assertRaisesRegex(ValueError, "ZIP data"):
            self.check_apk(stored=True, aligned=False)

    def test_malformed_elf_headers_and_segments(self):
        # Invalid table offset, entry size/count, segment congruence, bounds,
        # memory size, non-power-of-two alignment, and no PT_LOAD.
        cases = ((32, "Q", 1000), (54, "H", 0), (56, "H", 0),
                 (56, "H", 0xffff), (80, "Q", 1), (96, "Q", 129),
                 (104, "Q", 127), (112, "Q", 24576), (112, "Q", 0), (64, "I", 0))
        for offset, fmt, value in cases:
            data = elf_fixture()
            struct.pack_into("<" + fmt, data, offset, value)
            with self.subTest(offset=offset, value=value), self.assertRaises(ValueError):
                elf_load_alignments(data)
        for length in (0, 5, 15, 60, 100):
            with self.subTest(length=length), self.assertRaises(ValueError):
                elf_load_alignments(elf_fixture()[:length])


if __name__ == "__main__":
    unittest.main()
