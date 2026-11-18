#!/usr/bin/env python3
"""Run the M1 bundle stub in its own temporary data folder; never launch via Finder."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
binary = root / "build/Apparate.app/Contents/MacOS/Apparate"
assert binary.is_file(), "Run ./build.sh first"
with tempfile.TemporaryDirectory(prefix="apparate-m1-app-") as directory:
    config = Path(directory) / "config.json"
    process = subprocess.Popen([str(binary)], env={**os.environ, "APPARATE_HOME": directory},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while not config.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        assert process.poll() is None, "App exited before readiness"
        assert config.exists(), "App did not write config.json in APPARATE_HOME"
        raw = config.read_bytes()
        value = json.loads(raw)
        assert value["version"] == 1 and value["showMenuBarIcon"] is True
        assert value["prefixes"] == {"files": "'", "settings": ".", "web": "?"}
        assert value["searchURL"] == "https://duckduckgo.com/?q={query}"
        assert sorted(p.name for p in Path(directory).iterdir()) == ["config.json"]
        result = {"result": "Passed", "readiness": "Process alive; defaults written only under APPARATE_HOME",
                  "config_sha256": hashlib.sha256(raw).hexdigest(), "created_files": ["config.json"],
                  "launch": "direct bundle executable; accessory app stub; no window or action entry points"}
    finally:
        if process.poll() is None:
            process.terminate()
        stdout, stderr = process.communicate(timeout=5)
    result["stdout_bytes"] = len(stdout)
    result["stderr_bytes"] = len(stderr)
    assert b"Could not load config" not in stderr and b"Config:" not in stderr, "App logged a config error"
result["cleanup"] = "Process stopped; only the test-created temporary folder removed"
print(json.dumps(result, indent=2, sort_keys=True))
