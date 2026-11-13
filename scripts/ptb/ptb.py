#!/usr/bin/env python3
"""ptb: PokeTokenBar_gs for Linux servers and other computers without the Mac app.

  ptb install   set up the `ptb` command and a cron job that pushes usage every 30 minutes
  ptb login     sign in with the same Google account as the Mac app (once)
  ptb push      count this computer's Claude Code / Codex tokens and upload the daily totals
  ptb status    show the companion, egg and currency from the latest save in Google Drive
  ptb dex       show the Pokédex from that save

The Mac app is the only place that grows the companion: it adds this computer's usage to the
save on its next sync. This tool never changes the save. Python 3.9+, standard library only.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import urllib.request

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import google_sync as cloud  # noqa: E402
import ptb_collect  # noqa: E402

HOME = Path(os.environ.get("PTB_HOME", HERE)).expanduser()
CRON_MARK = "# poketokenbar-gs ptb push"


def state_dir():
    return cloud.private_directory(HOME / "google-sync")


def config():
    path = HOME / "config.json"
    if path.exists():
        return json.loads(path.read_text())
    return {}


def save_config(value):
    cloud.atomic_json(HOME / "config.json", value)


def client_file():
    for candidate in (HOME / "oauth-client.json", Path("~/.config/poketokenbar-gs/oauth-client.json").expanduser()):
        if candidate.exists():
            return candidate
    raise cloud.SyncError("oauth-client.json not found. Copy it next to ptb.py (see the README).")


# MARK: install / login

def install(args):
    cfg = config()
    cfg["timezone"] = args.timezone or cfg.get("timezone") or "Asia/Seoul"
    cfg["deviceName"] = args.name or cfg.get("deviceName") or socket.gethostname()
    claude = [str(Path(p).expanduser()) for p in (args.claude_root or ["~/.claude/projects"])]
    codex = [str(Path(p).expanduser()) for p in (args.codex_root or ["~/.codex/sessions", "~/.codex/archived_sessions"])]
    cfg["claudeRoots"] = [p for p in claude if Path(p).is_dir()]
    cfg["codexRoots"] = [p for p in codex if Path(p).is_dir()]
    save_config(cfg)
    bin_dir = Path("~/.local/bin").expanduser()
    bin_dir.mkdir(parents=True, exist_ok=True)
    launcher = bin_dir / "ptb"
    launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(HERE / 'ptb.py'))} \"$@\"\n")
    launcher.chmod(0o755)
    line = f"*/{args.interval} * * * * {shlex.quote(str(launcher))} push --quiet >> {shlex.quote(str(HOME / 'push.log'))} 2>&1 {CRON_MARK}"
    current = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    lines = [l for l in (current.stdout.splitlines() if current.returncode == 0 else []) if CRON_MARK not in l]
    subprocess.run(["crontab", "-"], input="\n".join(lines + [line]) + "\n", text=True, check=True)
    print(f"Installed {launcher} and a cron job every {args.interval} minutes.")
    print(f"Device name: {cfg['deviceName']} · timezone: {cfg['timezone']}")
    print(f"Claude logs: {', '.join(cfg['claudeRoots']) or 'none found'}")
    print(f"Codex logs:  {', '.join(cfg['codexRoots']) or 'none found'}")
    if str(bin_dir) not in os.environ.get("PATH", "").split(":"):
        print(f"Add {bin_dir} to PATH, or run {launcher} directly.")
    print("Next: ptb login")


def uninstall(_args):
    current = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    if current.returncode == 0:
        lines = [l for l in current.stdout.splitlines() if CRON_MARK not in l]
        subprocess.run(["crontab", "-"], input="\n".join(lines) + ("\n" if lines else ""), text=True, check=True)
    print("Removed the cron job. Sign-in and files are kept; delete this folder to remove everything.")


def login(args):
    # A server has no browser: print the URL to open on the Mac through `ssh -L`.
    no_browser = args.no_browser or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
    if no_browser:
        print(f"On your Mac, keep this open first:  ssh -L {args.port}:127.0.0.1:{args.port} <this server>", file=sys.stderr)
    result = cloud.authorize(state_dir(), str(client_file()), args.port, no_browser)
    print(f"Signed in as {result['account'].get('email', '')}")
    print("Next: ptb push")


def logout(_args):
    path = state_dir() / "credentials.json"
    if path.exists():
        path.unlink()
    print("Signed out on this computer.")


# MARK: push

def collect_days(cfg):
    roots_c, roots_x = cfg.get("claudeRoots", []), cfg.get("codexRoots", [])
    if not roots_c and not roots_x:
        raise cloud.SyncError("No Claude Code or Codex log folder configured; run ptb install again")
    collector = ptb_collect.Collector(HOME / "collector", cfg.get("timezone", "Asia/Seoul"))
    try:
        collector.scan([r for r in roots_c if Path(r).is_dir()], [r for r in roots_x if Path(r).is_dir()])
        return collector.daily(cloud.USAGE_DAYS)
    finally:
        collector.close()


def push(args):
    if sys.platform == "darwin" and not args.allow_mac:
        # The Mac app already counts this Mac's logs; pushing them too would grow the companion twice.
        raise cloud.SyncError("On a Mac, the PokeTokenBar_gs app counts usage itself; ptb push is for other computers")
    cfg = config()
    days = collect_days(cfg)
    google = cloud.Google(state_dir())
    device = cloud.Sync(google, state_dir()).journal["device"]
    result = cloud.usage_push(google, device, cfg.get("deviceName") or socket.gethostname(), days)
    today = dt.datetime.now(ptb_collect.ZoneInfo(cfg.get("timezone", "Asia/Seoul"))).date().isoformat()
    line = f"{dt.datetime.now().isoformat(timespec='seconds')} pushed {result['days']} days, today {sum(days.get(today, {}).values()):,} tokens"
    print(line)   # also the cron log line


# MARK: status / dex

def latest_save(google):
    sync = cloud.Sync(google, state_dir())
    heads = cloud.heads(sync.records())
    if not heads:
        raise cloud.SyncError("No save in Google Drive yet. Sign in on the Mac app first.")
    heads.sort(key=lambda r: r.get("savedAt", ""), reverse=True)
    return sync.download(heads[0]), heads[0], len(heads)


def species_name(species, names, lang):
    by_lang = names.get(species) or {}
    if lang in by_lang or "en" in by_lang:
        return by_lang.get(lang) or by_lang["en"]
    cache_path = HOME / "names-cache.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    key = f"{species}:{lang}"
    if key not in cache:
        try:
            # PokeAPI's CDN rejects urllib's default User-Agent (HTTP 403).
            request = urllib.request.Request(f"https://pokeapi.co/api/v2/pokemon-species/{int(species)}",
                                             headers={"User-Agent": "ptb (PokeTokenBar_gs)"})
            with urllib.request.urlopen(request, timeout=10) as r:
                data = json.loads(r.read(512 * 1024))
            found = {n["language"]["name"]: n["name"] for n in data.get("names", [])}
            cache[key] = found.get(lang) or found.get("en") or f"#{species}"
            cloud.atomic_json(cache_path, cache)
        except (OSError, ValueError, KeyError):
            return f"#{species}"
    return cache[key]


def dex_names(state):
    names = {}
    for entry in state.get("dex", []):
        raw = entry.get("names") or {}
        # Swift encodes [Int: X] as a flat [key, value, key, value] array.
        pairs = zip(raw[::2], raw[1::2]) if isinstance(raw, list) else raw.items()
        for species, by_lang in pairs:
            if isinstance(by_lang, dict):
                names[int(species)] = by_lang
    return names


def language(args):
    return args.lang or ("ko" if os.environ.get("LANG", "").startswith("ko") else "en")


def status(args):
    google = cloud.Google(state_dir())
    save, head, branches = latest_save(google)
    state, lang = save["state"], language(args)
    names = dex_names(state)
    print(f"Save from {head.get('deviceName', '?')} at {head.get('savedAt', '?')}")
    if branches > 1:
        print(f"  ({branches} unresolved saves; choose one in the Mac app)")
    active = state.get("active")
    if active:
        path = active.get("pathIDs") or [active.get("baseID")]
        current = path[min(active.get("stageIndex", 0), len(path) - 1)]
        shiny = " ✨" if active.get("isShiny") else ""
        print(f"Companion: {species_name(current, names, lang)}{shiny} · {active.get('rarity', '?')} · "
              f"stage {active.get('stageIndex', 0) + 1}/{len(path)} · {active.get('usedAtStage', 0):,} tokens at this stage")
    else:
        print(f"Egg: {state.get('eggUsage', 0):,} tokens incubated")
    used, spent = state.get("usedSinceInstall", 0), state.get("spentTokens", 0)
    print(f"Tokens: {used:,} total · {used - spent:,} to spend")
    inventory = {k: v for k, v in (state.get("inventory") or {}).items() if v}
    if inventory:
        print("Items: " + ", ".join(f"{k} ×{v}" for k, v in sorted(inventory.items())))
    print(f"Pokédex: {len(state.get('dex', []))} records")
    others = cloud.usage_list(google)["devices"]
    if others:
        today = dt.datetime.now(ptb_collect.ZoneInfo(config().get("timezone", "Asia/Seoul"))).date().isoformat()
        print("Usage today: " + " · ".join(
            f"{d['deviceName']} {sum(d['days'].get(today, {}).values()):,}" for d in others))


def dex(args):
    google = cloud.Google(state_dir())
    save, _, _ = latest_save(google)
    state, lang = save["state"], language(args)
    names = dex_names(state)
    entries = sorted(state.get("dex", []), key=lambda e: (e.get("finalID", 0), e.get("caughtAt") or 0))
    if not entries:
        print("No Pokédex records yet.")
        return
    for e in entries:
        chain = " → ".join(species_name(s, names, lang) for s in e.get("chainOrder") or [e.get("finalID")])
        tags = [e.get("rarity", "")]
        if e.get("isShiny"):
            tags.append("shiny")
        if e.get("releasedAt"):
            tags.append("released")
        print(f"#{e.get('finalID', 0):>4}  {chain}  ({', '.join(t for t in tags if t)})")
    shiny = sum(1 for e in entries if e.get("isShiny"))
    print(f"{len(entries)} records · {len({e.get('finalID') for e in entries})} species · {shiny} shiny")


def main():
    parser = argparse.ArgumentParser(prog="ptb", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("install", help="install the ptb command and the cron job")
    p.add_argument("--timezone", help="day boundary for usage; use the Mac's timezone (default Asia/Seoul)")
    p.add_argument("--name", help="device name shown in the Mac app (default: hostname)")
    p.add_argument("--interval", type=int, default=30, choices=[5, 10, 15, 20, 30], help="minutes between pushes")
    p.add_argument("--claude-root", action="append", help="Claude Code projects folder (default ~/.claude/projects)")
    p.add_argument("--codex-root", action="append", help="Codex sessions folder (default ~/.codex/sessions)")
    p.set_defaults(run=install)
    sub.add_parser("uninstall", help="remove the cron job").set_defaults(run=uninstall)
    p = sub.add_parser("login", help="sign in with Google (once)")
    p.add_argument("--no-browser", action="store_true", help="print the URL instead of opening a browser")
    p.add_argument("--port", type=int, default=8765, help="loopback port; forward it with ssh -L")
    p.set_defaults(run=login)
    sub.add_parser("logout", help="forget the Google sign-in on this computer").set_defaults(run=logout)
    p = sub.add_parser("push", help="upload this computer's daily token totals")
    p.add_argument("--quiet", action="store_true", help="accepted for cron; output is one line either way")
    p.add_argument("--allow-mac", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(run=push)
    for name, fn in (("status", status), ("dex", dex)):
        p = sub.add_parser(name, help=f"show the {name} from the latest Drive save")
        p.add_argument("--lang", help="name language, e.g. ko, en, ja")
        p.set_defaults(run=fn)
    args = parser.parse_args()
    os.umask(0o077)
    HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.run(args)


if __name__ == "__main__":
    try:
        main()
    except (cloud.SyncError, OSError, ValueError, KeyError, TypeError) as error:
        print(f"ptb: {error}", file=sys.stderr)
        sys.exit(1)
