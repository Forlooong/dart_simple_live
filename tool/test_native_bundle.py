import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from verify_native_bundle import ANDROID_ABIS, LIBRARIES, elf_load_alignments, verify_android


def elf_fixture(bits, alignment):
    """One PT_LOAD segment, sufficient to inspect the packaged ELF header."""
    data = bytearray(128)
    data[:6] = b"\x7fELF" + bytes((1 if bits == 32 else 2, 1))
    if bits == 32:
        struct.pack_into("<I", data, 28, 64)
        struct.pack_into("<HH", data, 42, 32, 1)
        struct.pack_into("<I", data, 92, alignment)
    else:
        struct.pack_into("<Q", data, 32, 64)
        struct.pack_into("<HH", data, 54, 56, 1)
        struct.pack_into("<Q", data, 112, alignment)
    struct.pack_into("<I", data, 64, 1)
    return data


class NativeBundleTest(unittest.TestCase):
    def test_read_both_elf_classes(self):
        self.assertEqual(elf_load_alignments(elf_fixture(32, 16384)), [16384])
        self.assertEqual(elf_load_alignments(elf_fixture(64, 65536)), [65536])

    def test_missing_quickjs_or_small_load_alignment_fails_packaging(self):
        for missing, alignment in ((False, 16384), (True, 16384), (False, 4096)):
            with self.subTest(missing=missing, alignment=alignment), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp)
                for abi in ANDROID_ABIS:
                    with zipfile.ZipFile(directory / f"app-{abi}-release.apk", "w") as archive:
                        for library in LIBRARIES:
                            if missing and library == "dart_quickjs":
                                continue
                            archive.writestr(f"lib/{abi}/lib{library}.so",
                                             elf_fixture(32 if abi == "armeabi-v7a" else 64, alignment))
                with contextlib.redirect_stdout(io.StringIO()):
                    if missing or alignment < 16384:
                        with self.assertRaises(ValueError):
                            verify_android(directory)
                    else:
                        verify_android(directory)


if __name__ == "__main__":
    unittest.main()
