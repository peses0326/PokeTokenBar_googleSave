#!/usr/bin/env python3
"""Install the Mac's half-hourly pull after testing SSH and the server collector."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

LABEL = "local.poketokenbar.remote-summary"


def job(state, pull, server, command):
    return {
        "Label": LABEL,
        "ProgramArguments": ["/bin/bash", str(pull), server, command],
        "EnvironmentVariables": {"PTB_STATE_DIR": str(state)},
        "RunAtLoad": True,
        "StartCalendarInterval": [{"Minute": 0}, {"Minute": 30}],
        "ProcessType": "Background", "LowPriorityIO": True, "Nice": 10,
        "StandardOutPath": str(state / "remote-sync.log"),
        "StandardErrorPath": str(state / "remote-sync-error.log"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server", help="Existing SSH config alias, e.g. poke-usage-server")
    parser.add_argument("--command", default=".local/share/poketokenbar-remote/run.sh",
                        help="Trusted remote shell command that outputs only the summary JSON")
    args = parser.parse_args()
    if args.server.startswith("-"):
        parser.error("SSH server must not start with '-'")
    os.umask(0o077)
    state = Path(os.environ.get("PTB_STATE_DIR") or Path.home() / "Library/Application Support/PokeTokenBar").resolve()
    scripts = state / "remote-sync"
    scripts.mkdir(parents=True, exist_ok=True)
    pull = scripts / "pull.sh"
    shutil.copyfile(Path(__file__).with_name("pull.sh"), pull)
    # Do not register a recurring job until a real SSH invocation succeeds.
    env = dict(os.environ, PTB_STATE_DIR=str(state))
    subprocess.run(["/bin/bash", str(pull), args.server, args.command], check=True, env=env)
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    target = agents / (LABEL + ".plist")
    target.write_bytes(plistlib.dumps(job(state, pull, args.server, args.command)))
    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "bootout", f"{domain}/{LABEL}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["/bin/launchctl", "bootstrap", domain, str(target)], check=True)
    print(f"Installed: {target}\nSummary: {state / 'remote-usage.json'}")
    print("Schedule: every hour at :00 and :30; delayed jobs resume after sleep.")


if __name__ == "__main__":
    main()
