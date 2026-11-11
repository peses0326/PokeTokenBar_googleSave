import datetime as dt
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("collect", Path(__file__).with_name("collect.py"))
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.collector = collect.Collector(self.root / "state")
        self.now = dt.datetime(2026, 11, 9, 12, tzinfo=dt.timezone.utc)

    def tearDown(self):
        self.collector.close()
        self.temp.cleanup()

    def write(self, name, *records, append=False):
        with (self.logs / name).open("a" if append else "w") as f:
            for record in records:
                f.write(json.dumps(record) + "\n")

    def claude(self, id="m1", input=100, stamp="2026-11-09T00:00:00Z"):
        return {"type": "assistant", "timestamp": stamp, "requestId": "req",
                "message": {"id": id, "content": "PRIVATE_PROMPT", "usage": {
                    "input_tokens": input, "output_tokens": 20,
                    "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40}}}

    def meta(self, session="session1", parent=None):
        payload = {"id": session}
        if parent:
            payload["forked_from_id"] = parent
        return {"type": "session_meta", "payload": payload}

    def codex(self, input=100, cached=40, output=20, cumulative=None, stamp="2026-11-09T00:00:00Z"):
        usage = {"input_tokens": input, "cached_input_tokens": cached,
                 "output_tokens": output, "reasoning_output_tokens": 5, "total_tokens": input + output}
        return {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
            "last_token_usage": usage, "total_token_usage": cumulative or usage}}}

    def summary(self, provider):
        return self.collector.summary(self.now)["providers"][provider]

    def test_incremental_restart_partial_line_and_no_prompt_export(self):
        self.write("one.jsonl", self.claude())
        self.collector.scan([self.logs])
        first = self.summary("claude")
        self.assertEqual(first["totalTokens"], 190)
        self.assertEqual(first["days"][0]["cacheRead"], 40)
        self.assertNotIn("PRIVATE_PROMPT", json.dumps(self.collector.summary(self.now)))
        self.collector.close()
        self.collector = collect.Collector(self.root / "state")
        self.collector.scan([self.logs])
        self.assertEqual(self.collector.bytes_read, 0)
        tail = json.dumps(self.claude("m2", input=200))
        with (self.logs / "one.jsonl").open("a") as f:
            f.write(tail[:30])
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude"), first)
        with (self.logs / "one.jsonl").open("a") as f:
            f.write(tail[30:] + "\n")
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 480)
        self.assertLess(self.collector.bytes_read, 1000)

    def test_claude_streaming_copy_truncation_and_deletion(self):
        self.write("one.jsonl", self.claude())
        self.collector.scan([self.logs])
        self.write("copy.jsonl", self.claude(), self.claude(input=150))
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 240)
        self.write("one.jsonl", self.claude("m2", input=5))
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 335)
        for p in self.logs.iterdir():
            p.unlink()
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 335)

    def test_codex_duplicate_snapshots_fork_and_archive_move(self):
        first = self.codex()
        second = self.codex(input=200, cumulative={"input_tokens": 300, "cached_input_tokens": 80,
                                                 "output_tokens": 40, "total_tokens": 340})
        self.write("z-parent.jsonl", self.meta(), first, first)
        self.write("a-child.jsonl", self.meta("child", "session1"), first, second)
        self.collector.scan(codex_roots=[self.logs])
        self.assertEqual(self.summary("codex")["totalTokens"], 340)
        archive = self.logs / "archive"
        archive.mkdir()
        (self.logs / "z-parent.jsonl").rename(archive / "moved.jsonl")
        self.collector.scan(codex_roots=[self.logs, archive])
        self.assertEqual(self.summary("codex")["totalTokens"], 340)

    def test_real_fork_and_subagent_fixtures(self):
        fixtures = Path(__file__).resolve().parents[2] / "Tests/PokeTokenBarTests/Fixtures"
        shutil.copytree(fixtures / "CodexFork", self.logs / "CodexFork")
        self.collector.scan(codex_roots=[self.logs])
        # Fork parent 312814 + child 28138 + sibling 28263 + nested child 28569;
        # subagents add their own usage despite embedded parent session metadata.
        event_totals = dict(self.collector.db.execute(
            "SELECT session,SUM(input+output+cache_write+cache_read) FROM events GROUP BY session"))
        self.assertEqual(event_totals["00000000-0000-7000-8000-000000000002"], 28138)
        self.assertEqual(event_totals["00000000-0000-7000-8000-000000000004"], 28263)
        self.collector.close()
        self.collector = collect.Collector(self.root / "subagent-state")
        shutil.rmtree(self.logs)
        shutil.copytree(fixtures / "CodexSubagent", self.logs)
        self.collector.scan(codex_roots=[self.logs])
        event_totals = dict(self.collector.db.execute(
            "SELECT session,SUM(input+output+cache_write+cache_read) FROM events GROUP BY session"))
        self.assertEqual(event_totals["00000000-0000-7000-8000-000000000145"], 63403)
        self.assertIn(43180, event_totals.values())

    def test_missing_roots_and_malformed_lines_rollback(self):
        self.write("one.jsonl", self.claude())
        with (self.logs / "one.jsonl").open("a") as f:
            f.write('{"usage": broken}\n')
        with self.assertRaises(ValueError):
            self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 0)
        with self.assertRaises(ValueError):
            self.collector.scan([self.root / "missing"])

    def test_in_place_truncate_then_regrow_restarts_without_double_counting(self):
        self.write("one.jsonl", self.claude())
        self.collector.scan([self.logs])
        self.write("one.jsonl", self.claude(), self.claude("m2"), self.claude("m3"))
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 570)
        self.write("one.jsonl", self.claude("m4"), self.claude("m5"), self.claude("m6"), self.claude("m7"))
        self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 1330)

    def test_invalid_tokens_missing_fork_parent_and_source_identity(self):
        source = self.collector.summary(self.now)["sourceId"]
        self.write("one.jsonl", self.claude(input=-1))
        with self.assertRaises(ValueError):
            self.collector.scan([self.logs])
        self.assertEqual(self.summary("claude")["totalTokens"], 0)
        self.write("one.jsonl", self.meta("child", "missing-parent"), self.codex())
        with self.assertRaisesRegex(ValueError, "Missing Codex fork parent"):
            self.collector.scan(codex_roots=[self.logs])
        self.collector.close()
        self.collector = collect.Collector(self.root / "state")
        self.assertEqual(self.collector.summary(self.now)["sourceId"], source)

    def test_timezone_boundary_and_bounded_export_with_lifetime_total(self):
        self.write("one.jsonl", self.claude(stamp="2026-11-08T15:01:00Z"),
                   self.claude("old", stamp="2025-01-01T00:00:00Z"))
        self.collector.scan([self.logs])
        usage = self.summary("claude")
        self.assertEqual(usage["days"][0]["date"], "2026-11-09")
        self.assertEqual(len(usage["days"]), 1)
        self.assertEqual(usage["totalTokens"], 380)
        self.assertLess(len(json.dumps(self.collector.summary(self.now))), 1024)


if __name__ == "__main__":
    unittest.main()
