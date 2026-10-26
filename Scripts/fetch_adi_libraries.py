#!/usr/bin/env python3
"""Downloads the on-device Anisette libraries into GetMoreRam/ADI/.

Apple's ADI libraries are required by AnisetteKit's emulated provider. They are not
committed to the repository, so this script has to run once before building, and on
every CI run. It is idempotent.
"""

import base64
import io
import json
import os
import sys
import urllib.request
import zipfile

SOURCE = "https://zzz.haus/oda.json"
LIBRARIES = ("libCoreADI.so", "libstoreservicescore.so")

REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET_DIRECTORY = os.path.join(REPOSITORY_ROOT, "ADI")


def main() -> int:
    os.makedirs(TARGET_DIRECTORY, exist_ok=True)

    if all(os.path.isfile(os.path.join(TARGET_DIRECTORY, name)) for name in LIBRARIES):
        print(f"ADI libraries already present in {TARGET_DIRECTORY}")
        return 0

    with urllib.request.urlopen(SOURCE, timeout=60) as response:
        metadata = json.load(response)

    payload = base64.b64decode(metadata["l"])

    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for name in LIBRARIES:
            data = archive.read(name)
            with open(os.path.join(TARGET_DIRECTORY, name), "wb") as handle:
                handle.write(data)
            print(f"{name}: {len(data)} bytes")

    return 0


if __name__ == "__main__":
    sys.exit(main())
