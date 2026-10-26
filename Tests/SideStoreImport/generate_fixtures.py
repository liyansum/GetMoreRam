"""Generate synthetic test exports only; never reads a user's account export."""
import base64
import hashlib
import json
import pathlib
import sys

folder = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(folder.parent / "ssh-deps"))
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

blob = base64.b64encode(b"synthetic-not-real-anisette-blob").decode()
identifier = base64.b64encode(bytes(range(16))).decode()
legacy = {"email": "fixture@example.invalid", "password": "  NOT_A_REAL_PASSWORD  ",
          "adiPB": blob, "local_user": identifier}
modern = {"version": "2.0", "email": "fixture@example.invalid", "anisetteAdiBlob": blob,
          "anisetteIdentifier": "00000000-1111-2222-3333-444444444444",
          "certificateData": "ignored-synthetic-field", "certType": "unencrypted"}
modern_base64 = dict(modern, anisetteIdentifier=identifier)
legacy_keys_v2 = dict(legacy, version="2.0")
modern_no_version = dict(modern_base64)
del modern_no_version["version"]
for name, payload in (("legacy", legacy), ("modern_uuid", modern),
                      ("modern_base64", modern_base64), ("legacy_keys_v2", legacy_keys_v2),
                      ("modern_no_version", modern_no_version)):
    (folder / f"{name}.json").write_text(json.dumps(payload), encoding="utf-8")
(folder / "legacy_bom.json").write_bytes(b"\xef\xbb\xbf" + json.dumps(legacy).encode())

salt = b"{fixture-salt-01"
assert len(salt) == 16
nonce = bytes(range(12))
password = "NOT_A_REAL_FILE_PASSWORD_\U0001f510"
key = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 10_000, 32)
plain = json.dumps(modern_base64).encode()
encrypted = salt + nonce + AESGCM(key).encrypt(nonce, plain, None)
(folder / "synthetic.sideconf").write_bytes(encrypted)
print("Synthetic fixtures generated; no user exports were read.")
