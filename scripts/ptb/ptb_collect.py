#!/usr/bin/env python3
"""Incremental Claude Code / Codex usage collector for `ptb push`. Python 3.9+, stdlib only.

SQLite stores read offsets and token counts, never prompts or code. Only new log lines are read
after the first run. Token totals match the Mac app: input + output + cache write + cache read.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid
from zoneinfo import ZoneInfo

MAX_LINE = 16 * 1024 * 1024
MAX_TOKENS = 10**15


def integer(value):
    if type(value) is not int or not 0 <= value <= MAX_TOKENS:
        raise ValueError("Invalid token count")
    return value


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Missing usage timestamp")
    result = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if result.tzinfo is None:
        raise ValueError("Usage timestamp must include a timezone")
    return result


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Collector:
    def __init__(self, directory, timezone="Asia/Seoul"):
        self.directory = Path(directory).expanduser()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = open(self.directory / "collector.lock", "a")
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.db = sqlite3.connect(self.directory / "usage.sqlite3")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files (
                path TEXT PRIMARY KEY, device INTEGER, inode INTEGER, offset INTEGER,
                size INTEGER, mtime INTEGER, metadata TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (
                provider TEXT, key TEXT, session TEXT, signature TEXT, day TEXT,
                stamp TEXT, input INTEGER, output INTEGER, cache_write INTEGER,
                cache_read INTEGER, PRIMARY KEY(provider, key));
            CREATE INDEX IF NOT EXISTS session_signature ON events(session, signature);
            CREATE INDEX IF NOT EXISTS provider_stamp ON events(provider, stamp);
            CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, parent TEXT);
            CREATE TABLE IF NOT EXISTS days (
                provider TEXT, day TEXT, input INTEGER, output INTEGER,
                cache_write INTEGER, cache_read INTEGER, PRIMARY KEY(provider, day));
        """)
        self.db.execute("INSERT OR IGNORE INTO config VALUES ('source', ?)", (str(uuid.uuid4()),))
        self.db.execute("INSERT OR IGNORE INTO config VALUES ('timezone', ?)", (timezone,))
        stored = self.db.execute("SELECT value FROM config WHERE key='timezone'").fetchone()[0]
        if stored != timezone:
            raise ValueError("Timezone changed; use a new state directory instead of reinterpreting old totals")
        self.zone = ZoneInfo(timezone)
        self.db.commit()
        self.bytes_read = 0

    def close(self):
        self.db.close()
        self.lock.close()

    def add(self, provider, key, session, signature, stamp, counts):
        date = timestamp(stamp)
        day = date.astimezone(self.zone).date().isoformat()
        stamp = date.astimezone(dt.timezone.utc).isoformat()
        counts = tuple(integer(x) for x in counts)
        old = self.db.execute(
            "SELECT input,output,cache_write,cache_read FROM events WHERE provider=? AND key=?",
            (provider, key)).fetchone()
        # Claude streaming snapshots and copied transcripts can repeat a message with
        # more complete usage. Keep the largest complete record, not the sum of copies.
        if old and sum(old) >= sum(counts):
            return
        if old:
            old_day = self.db.execute("SELECT day FROM events WHERE provider=? AND key=?",
                                      (provider, key)).fetchone()[0]
            self.adjust(provider, old_day, tuple(-x for x in old))
        self.db.execute("INSERT OR REPLACE INTO events VALUES (?,?,?,?,?,?,?,?,?,?)",
                        (provider, key, session, signature, day, stamp, *counts))
        self.adjust(provider, day, counts)

    def adjust(self, provider, day, counts):
        self.db.execute("""INSERT INTO days VALUES (?,?,?,?,?,?)
            ON CONFLICT(provider,day) DO UPDATE SET
            input=input+excluded.input, output=output+excluded.output,
            cache_write=cache_write+excluded.cache_write, cache_read=cache_read+excluded.cache_read
            """, (provider, day, *counts))

    def ancestor_has(self, parent, signature):
        visited = set()
        while parent and parent not in visited:
            visited.add(parent)
            if self.db.execute("SELECT 1 FROM events WHERE session=? AND signature=? LIMIT 1",
                               (parent, signature)).fetchone():
                return True
            row = self.db.execute("SELECT parent FROM sessions WHERE id=?", (parent,)).fetchone()
            parent = row[0] if row else None
        return False

    def claude(self, obj):
        if obj.get("type") != "assistant":
            return
        msg = obj.get("message") or {}
        usage = msg.get("usage")
        if not isinstance(usage, dict) or not msg.get("id"):
            return
        counts = [usage.get(k, 0) for k in (
            "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")]
        self.add("claude", digest([msg["id"], obj.get("requestId")]), "", "",
                 obj.get("timestamp"), counts)

    def codex(self, obj, meta):
        payload = obj.get("payload") or {}
        if obj.get("type") == "session_meta":
            session = payload.get("id") or payload.get("session_id")
            if not session:
                raise ValueError("Codex session_meta is missing its ID")
            if "session" not in meta:
                source = payload.get("source")
                subagent = isinstance(source, dict) and "subagent" in source
                meta.update(session=session, parent=payload.get("forked_from_id") or
                            payload.get("parent_thread_id"), replaying=not subagent, subagent=subagent)
                self.db.execute("INSERT OR REPLACE INTO sessions VALUES (?,?)",
                                (session, meta["parent"]))
            meta["current"] = session
            return
        if obj.get("type") != "event_msg" or payload.get("type") != "token_count":
            return
        info = payload.get("info")
        if not isinstance(info, dict) or not isinstance(info.get("last_token_usage"), dict):
            return  # Rate-limit-only notifications carry no usage.
        if "session" not in meta:
            raise ValueError("Codex token_count precedes session_meta")
        last = info["last_token_usage"]
        cumulative = info.get("total_token_usage")
        # Canonicalize counters: cosmetic fields or key order must not create new events.
        keys = ("input_tokens", "cached_input_tokens", "output_tokens",
                "reasoning_output_tokens", "total_tokens")
        last_vector = [integer(last.get(k, 0)) for k in keys]
        total_vector = [integer(cumulative.get(k, 0)) for k in keys] if isinstance(cumulative, dict) else None
        signature = digest([total_vector, last_vector]) if total_vector is not None else digest(
            [obj.get("timestamp"), last_vector])
        parent = meta.get("parent")
        if parent and meta.get("replaying"):
            if self.ancestor_has(parent, signature):
                return
            meta["replaying"] = False
        input_total, cached, output, _, total = last_vector
        if cached > input_total:
            raise ValueError("Codex cached input exceeds input total")
        counts = [input_total - cached, output, 0, cached]
        if sum(counts) == 0 and total:
            # Zero-context replay events can carry an unrelated total. Only trust a
            # genuinely total-only cumulative vector or the sole/first cumulative turn.
            previous = meta.get("previous_total")
            if total_vector and (sum(total_vector[:3]) == 0 or total == total_vector[4] or
                                 (previous and total_vector[4] > previous[4])):
                counts[0] = total
        owner = meta["session"] if parent else meta.get("current", meta["session"])
        if owner != meta.get("previous_owner"):
            meta["epoch"] = 0
            meta.pop("previous_total", None)
        previous = meta.get("previous_total")
        if previous and total_vector and any(a < b for a, b in zip(total_vector, previous)):
            meta["epoch"] = meta.get("epoch", 0) + 1
        meta["previous_total"] = total_vector
        meta["previous_owner"] = owner
        if sum(counts):
            self.add("codex", digest([owner, meta.get("epoch", 0), signature]), owner,
                     signature, obj.get("timestamp"), counts)

    def scan_file(self, path, provider):
        path = Path(path).resolve()
        with path.open("rb") as stream:
            stat = os.fstat(stream.fileno())
            row = self.db.execute("SELECT device,inode,offset,size,mtime,metadata FROM files WHERE path=?",
                                  (str(path),)).fetchone()
            offset, meta = 0, {}
            if row and row[0:2] == (stat.st_dev, stat.st_ino) and stat.st_size >= row[2]:
                offset, meta = row[2], json.loads(row[5])
                if stat.st_size == row[3] and stat.st_mtime_ns == row[4]:
                    return
                if offset:
                    stream.seek(max(0, offset - 256))
                    anchor = hashlib.sha256(stream.read(min(offset, 256))).hexdigest()
                    if anchor != meta.get("_anchor"):
                        offset, meta = 0, {}  # Truncated then regrown between scans.
                if stat.st_size == row[3] and stat.st_mtime_ns != row[4]:
                    offset, meta = 0, {}  # Same-size rewrite: reparse with event dedup.
            stream.seek(offset)
            while True:
                start = stream.tell()
                line = stream.readline(MAX_LINE + 1)
                self.bytes_read += len(line)
                if not line:
                    break
                if len(line) > MAX_LINE:
                    # Bound memory even for huge tool output lines; usage lines this
                    # large are rejected rather than silently discarded.
                    while line and not line.endswith(b"\n"):
                        line = stream.readline(MAX_LINE + 1)
                        self.bytes_read += len(line)
                    raise ValueError(f"JSONL line exceeds {MAX_LINE} bytes: {path}")
                if not line.endswith(b"\n"):
                    stream.seek(start)  # Retry incomplete writes on the next run.
                    break
                if provider == "claude" and b'"usage"' not in line:
                    continue
                if provider == "codex" and b"session_meta" not in line and b"token_count" not in line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, UnicodeDecodeError) as exc:
                    raise ValueError(f"Malformed usage JSONL in {path} at byte {start}") from exc
                if not isinstance(obj, dict):
                    raise ValueError(f"Expected JSON object in {path}")
                if provider == "claude":
                    self.claude(obj)
                else:
                    self.codex(obj, meta)
            end = stream.tell()
            stream.seek(max(0, end - 256))
            meta["_anchor"] = hashlib.sha256(stream.read(min(end, 256))).hexdigest()
            self.db.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?,?)",
                            (str(path), stat.st_dev, stat.st_ino, end, stat.st_size,
                             stat.st_mtime_ns, json.dumps(meta)))

    def scan(self, claude_roots=(), codex_roots=()):
        with self.db:
            for roots, provider in ((claude_roots, "claude"), (codex_roots, "codex")):
                paths = set()
                for root in roots:
                    root = Path(root).expanduser().resolve()
                    if not root.is_dir():
                        raise ValueError(f"Configured log root does not exist: {root}")
                    # A walk is metadata-only for unchanged files; file content is not reread.
                    def onerror(error):
                        raise error
                    for directory, _, files in os.walk(root, onerror=onerror):
                        paths.update(Path(directory, name).resolve() for name in files if name.endswith(".jsonl"))
                if provider == "codex":
                    # Parent-first traversal, independent of filenames and archive location.
                    headers = {}
                    for path in sorted(paths):
                        row = self.db.execute("SELECT metadata FROM files WHERE path=?", (str(path),)).fetchone()
                        meta = json.loads(row[0]) if row else {}
                        if not meta.get("session"):
                            with path.open("rb") as stream:
                                header = stream.readline(MAX_LINE + 1)
                            if len(header) > MAX_LINE:
                                raise ValueError(f"Oversized Codex header: {path}")
                            try:
                                obj = json.loads(header)
                            except ValueError:
                                obj = {}
                            payload = obj.get("payload") or {}
                            if obj.get("type") == "session_meta":
                                meta = {"session": payload.get("id") or payload.get("session_id"),
                                        "parent": payload.get("forked_from_id") or payload.get("parent_thread_id")}
                        headers[path] = meta
                    by_id = {}
                    for path, meta in headers.items():
                        if meta.get("session"):
                            by_id.setdefault(meta["session"], []).append(path)
                    done, visiting = set(), set()
                    def visit(path):
                        if path in done:
                            return
                        if path in visiting:
                            raise ValueError("Cyclic Codex fork ancestry")
                        visiting.add(path)
                        parent = headers[path].get("parent")
                        if parent in by_id:
                            for parent_path in by_id[parent]:
                                visit(parent_path)
                        elif parent and not self.db.execute("SELECT 1 FROM sessions WHERE id=?", (parent,)).fetchone():
                            # Real subagents do not replay parent usage; their header
                            # is checked by scan_file. Manual forks need parent history.
                            with path.open("rb") as stream:
                                first = json.loads(stream.readline(MAX_LINE + 1))
                            origin = (first.get("payload") or {}).get("source")
                            if not (isinstance(origin, dict) and "subagent" in origin):
                                raise ValueError(f"Missing Codex fork parent {parent}; include its active/archive root")
                        self.scan_file(path, provider)
                        visiting.remove(path)
                        done.add(path)
                    for path in sorted(paths):
                        visit(path)
                else:
                    for path in sorted(paths):
                        self.scan_file(path, provider)

    def daily(self, days=14, now=None):
        """{day: {provider: tokens}} for the last `days` days, in the collector's timezone."""
        now = now or dt.datetime.now(dt.timezone.utc)
        cutoff = (now.astimezone(self.zone).date() - dt.timedelta(days=days - 1)).isoformat()
        result = {}
        for provider, day, tokens in self.db.execute(
                "SELECT provider, day, input+output+cache_write+cache_read FROM days WHERE day>=? ORDER BY day",
                (cutoff,)):
            if tokens > 0:
                result.setdefault(day, {})[provider] = tokens
        return result

    def summary(self, now=None):
        now = now or dt.datetime.now(dt.timezone.utc)
        cutoff = (now.astimezone(self.zone).date() - dt.timedelta(days=61)).isoformat()
        providers = {}
        for provider in ("claude", "codex"):
            rows = self.db.execute("SELECT day,input,output,cache_write,cache_read FROM days "
                                   "WHERE provider=? AND day>=? ORDER BY day", (provider, cutoff))
            days = [dict(zip(("date", "input", "output", "cacheWrite", "cacheRead"), row)) for row in rows]
            total = self.db.execute("SELECT COALESCE(SUM(input+output+cache_write+cache_read),0) "
                                    "FROM days WHERE provider=?", (provider,)).fetchone()[0]
            last = self.db.execute("SELECT MAX(stamp) FROM events WHERE provider=?", (provider,)).fetchone()[0]
            providers[provider] = {"totalTokens": total, "lastUsage": last, "days": days}
        return {"version": 1, "sourceId": self.db.execute("SELECT value FROM config WHERE key='source'").fetchone()[0],
                "timezone": self.zone.key, "generatedAt": now.isoformat(), "providers": providers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--timezone", default="Asia/Seoul")
    parser.add_argument("--claude-root", action="append", default=[])
    parser.add_argument("--codex-root", action="append", default=[])
    args = parser.parse_args()
    if not args.claude_root and not args.codex_root:
        parser.error("At least one explicit log root is required")
    os.umask(0o077)
    collector = Collector(args.state_dir, args.timezone)
    try:
        collector.scan(args.claude_root, args.codex_root)
        print(json.dumps(collector.summary(), separators=(",", ":")))
        print(f"Usage collector: read {collector.bytes_read} new bytes", file=sys.stderr)
    finally:
        collector.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Usage collector failed: {error}", file=sys.stderr)
        sys.exit(1)
