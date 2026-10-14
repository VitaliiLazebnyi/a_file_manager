#!/usr/bin/env python3
"""Fails unless the SBOM names every package of the lock file, at the version the lock file has.

Usage: Scripts/sbom-check.py build/sbom.spdx.json Package.resolved
"""

import json
import sys


def main() -> int:
    sbom, resolved = (json.load(open(path)) for path in sys.argv[1:3])
    listed = {(package["name"], package.get("versionInfo")) for package in sbom["packages"]}
    missing = [
        f"{pin['identity']} {pin['state'].get('version')}"
        for pin in resolved["pins"]
        if (pin["identity"], pin["state"].get("version")) not in listed
    ]
    for entry in missing:
        print(f"missing from the SBOM: {entry}")
    print(f"sbom: {len(sbom['packages'])} package(s), {len(missing)} missing", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
