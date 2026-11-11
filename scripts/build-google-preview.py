#!/usr/bin/env python3
"""Build PokemonTokenBar_gs (Apple Silicon); never replace or launch the installed PokeTokenBar."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--products-dir", type=Path, help="Use an already built Swift product directory")
    parser.add_argument("--google-client-id", default=os.environ.get("PTB_GOOGLE_CLIENT_ID"), help="Developer's registered Desktop OAuth client ID")
    parser.add_argument("--oauth-client-config", type=Path, help="Developer build input only; users never select this JSON")
    parser.add_argument("--allow-unconfigured", action="store_true", help="Build an explicitly disabled sign-in preview")
    parser.add_argument("--output-dir", type=Path, help="Package separately from a currently running preview")
    args = parser.parse_args()
    client_id, client_secret = args.google_client_id, ""
    if args.oauth_client_config:
        config = json.loads(args.oauth_client_config.read_text()).get("installed", {})
        client_id, client_secret = config.get("client_id"), config.get("client_secret", "")
    if client_id and not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
        parser.error("Invalid Google Desktop OAuth client ID")
    if not client_id and not args.allow_unconfigured:
        parser.error("Set --google-client-id once for this app. End users sign in directly without a JSON file.")
    repo = Path(__file__).resolve().parents[1]
    if not args.skip_build:
        subprocess.run(["swift", "build", "-c", "release", "--build-system", "native",
                        "-debug-info-format", "none"], cwd=repo, check=True)
    products = args.products_dir.resolve() if args.products_dir else Path(subprocess.run(
        ["swift", "build", "-c", "release", "--build-system", "native", "--show-bin-path"],
        cwd=repo, check=True, stdout=subprocess.PIPE, text=True).stdout.strip())
    name = "PokemonTokenBar_gs"
    app = (args.output_dir.resolve() if args.output_dir else repo / "build/google-preview") / (name + ".app")
    if app.exists():
        shutil.rmtree(app)
    executable = app / "Contents/MacOS/PokeTokenBar"
    executable.parent.mkdir(parents=True)
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    shutil.copy2(products / "PokeTokenBar", executable)
    shutil.copy2(repo / "assets/AppIcon.icns", resources / "AppIcon.icns")
    bundle = products / "PokeTokenBar_PokeTokenBar.bundle"
    if not bundle.is_dir():
        raise RuntimeError("Cloud helper resource bundle missing; rebuild the package")
    shutil.copytree(bundle, resources / bundle.name)
    info = {"CFBundleExecutable": "PokeTokenBar", "CFBundleIconFile": "AppIcon",
            "CFBundleIdentifier": "io.github.peses0326.pokemontokenbar-gs",
            "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3",
            "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
            "NSHighResolutionCapable": True, "PTBCloudPreview": True}
    if client_id:
        info["PTBGoogleOAuthClientID"] = client_id
        if client_secret:
            info["PTBGoogleOAuthClientSecret"] = client_secret
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
