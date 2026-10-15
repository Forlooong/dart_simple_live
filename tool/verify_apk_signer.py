"""Pin APK signing to a public certificate fingerprint; never read private keys."""
import argparse
import json
from pathlib import Path
import re

BASELINE = Path(__file__).with_name("signing-baseline.json")
PACKAGE_IDS = {"main": "com.xycz.simple_live", "tv": "com.xycz.simple_live_tv"}


def normalize(value):
    if not isinstance(value, str):
        raise ValueError("Certificate SHA-256 must be a string")
    value = value.replace(":", "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("Expected one SHA-256 certificate fingerprint (64 hexadecimal digits)")
    return value


def expected_signer(app, path=BASELINE):
    entry = json.loads(Path(path).read_text(encoding="utf-8"))[app]
    if entry.get("package_id") != PACKAGE_IDS[app]:
        raise ValueError(f"{app}: signing baseline package ID must remain {PACKAGE_IDS[app]}")
    if not entry.get("certificate_sha256"):
        raise ValueError(
            f"{app}: stable signing baseline is not configured. After authorized secure key setup, "
            "record only the public certificate SHA-256 in tool/signing-baseline.json. "
            "CI will not create a key or publish an unpinned APK.")
    return normalize(entry["certificate_sha256"])


def verify_report(app, report, path=BASELINE):
    expected = expected_signer(app, path)
    digests = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: (\S+)\s*$", report, re.M)
    if len(digests) != 1 or normalize(digests[0]) != expected:
        raise ValueError(f"{app}: APK signer does not match the pinned update baseline; refusing upload")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", choices=PACKAGE_IDS)
    parser.add_argument("report", nargs="?", type=Path)
    args = parser.parse_args()
    digest = (verify_report(args.app, args.report.read_text(encoding="utf-8"))
              if args.report else expected_signer(args.app))
    print(f"Verified {args.app} public signing baseline: {digest}")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError) as error:
        raise SystemExit(f"Signing baseline error: {error}") from None
