#!/usr/bin/env python3
"""Incrementally collect local CLI usage and upload only its summary to Google Drive."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sys

from collect import Collector


def helper_module():
    path = Path(__file__).with_name("google_sync.py")
    if not path.exists():
        path = Path(__file__).resolve().parents[2] / "Sources/PokeTokenBar/Resources/CloudSync/google_sync.py"
    spec = importlib.util.spec_from_file_location("google_sync", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    cloud = helper_module()
    config = cloud.read_json(args.config, cloud.MAX_SUMMARY)
    claude, codex = config.get("claude_roots", []), config.get("codex_roots", [])
    if not (claude or codex) or not isinstance(claude, list) or not isinstance(codex, list):
        raise cloud.SyncError("Configure at least one Claude or Codex log root")
    collector = Collector(config["collector_state"], config.get("timezone", "Asia/Seoul"))
    try:
        collector.scan(claude, codex)
        source = collector.summary()
        auth = Path(config["google_state"]).expanduser()
        auth.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (auth / "sync.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            google = cloud.Google(auth)
            cloud.Sync(google, auth).upload_usage(source)
        print(json.dumps({"status": "uploaded", "sourceId": source["sourceId"],
                          "newLogBytesRead": collector.bytes_read}, separators=(",", ":")))
    finally:
        collector.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No Google response bodies, prompts, or tokens are printed.
        print("Usage upload failed: " + (str(error) if type(error).__name__ == "SyncError" else
                                         "check log roots, Google sign-in, and network"), file=sys.stderr)
        sys.exit(1)
