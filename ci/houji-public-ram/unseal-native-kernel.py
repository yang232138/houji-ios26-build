"""Read the same-run native XNU artifact and restore only its verified inputs."""
import hashlib
import io
import json
import os
from pathlib import Path
import uuid
import zipfile
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

evidence = Path("out/kernel-evidence")
receipt = json.loads((evidence / "build.json").read_text())
if (receipt["workflow_commit"] != os.environ["GITHUB_SHA"] or
    receipt["public_commit"] != os.environ["HOUJI_PUBLIC_REVISION"] or
    receipt["scope"] != "linked native-root XNU (offline only)"):
    raise ValueError("Wrong native-root build provenance")
sealed = (evidence / "compiled.zip.aesgcm").read_bytes()
if hashlib.sha256(sealed).hexdigest() != receipt["archive_sha256"]:
    raise ValueError("Encrypted artifact differs from build receipt")
key = bytes.fromhex(os.environ["HOUJI_ARTIFACT_KEY"])
plain = AESGCM(key).decrypt(sealed[:12], sealed[12:], b"houji-23g90-native-root-offline-v1")
with zipfile.ZipFile(io.BytesIO(plain)) as zipped:
    inputs = {name: zipped.read(name) for name in ("mach.development.houji", "native-trial-id")}
for name, payload in inputs.items():
    if receipt["files"][name] != {"bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}:
        raise ValueError(f"Native artifact member differs: {name}")
trial_id = uuid.UUID(inputs["native-trial-id"].decode("ascii").strip())
if trial_id.version != 4:
    raise ValueError("Invalid native kernel/loader trial ID")
base = Path(os.environ["RUNNER_TEMP"]) / "houji-public-ram"
base.mkdir()
(base / "native-trial-id").write_text(str(trial_id) + "\n", encoding="ascii")
Path(os.environ["HOUJI_NATIVE_KERNEL"]).write_bytes(inputs["mach.development.houji"])

