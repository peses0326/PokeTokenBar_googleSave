#!/usr/bin/env python3
"""Package `ptb` (the Linux / non-Mac companion of PokeTokenBar_gs) into build/ptb.

Copy the folder to a server and install it there:

    python3 scripts/build-ptb.py --oauth-client-config ~/.config/poketokenbar-gs/oauth-client.json
    scp -r build/ptb <server>:~/.local/share/poketokenbar-gs
    ssh <server> python3 ~/.local/share/poketokenbar-gs/ptb.py install

The OAuth client JSON (with its secret) is copied with owner-only permissions; it never goes into git.
"""
import argparse
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--oauth-client-config", type=Path, required=True,
                        help="the same Desktop OAuth client JSON used for the Mac build")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/ptb")
    args = parser.parse_args()
    client = json.loads(args.oauth_client_config.expanduser().read_text()).get("installed", {})
    if not client.get("client_id", "").endswith(".apps.googleusercontent.com") or not client.get("client_secret"):
        parser.error("Expected a Desktop OAuth client JSON with client_id and client_secret")
    out = args.output_dir
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, mode=0o700)
    for source in (ROOT / "scripts/ptb/ptb.py", ROOT / "scripts/ptb/ptb_collect.py",
                   ROOT / "Sources/PokeTokenBar/Resources/CloudSync/google_sync.py"):
        shutil.copy2(source, out / source.name)
    target = out / "oauth-client.json"
    target.write_text(json.dumps({"installed": {"client_id": client["client_id"], "client_secret": client["client_secret"]}}))
    target.chmod(0o600)
    print(out)


if __name__ == "__main__":
    main()
