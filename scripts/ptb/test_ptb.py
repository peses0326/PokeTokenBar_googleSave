import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Sources/PokeTokenBar/Resources/CloudSync/google_sync.py"


class PtbTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "ptb"
        self.home.mkdir()
        # Same layout as the packaged folder: ptb.py next to google_sync.py and ptb_collect.py.
        for source in (HELPER, Path(__file__).with_name("ptb.py"), Path(__file__).with_name("ptb_collect.py")):
            shutil.copy(source, self.home / source.name)
        sys.path.insert(0, str(self.home))
        os.environ["PTB_HOME"] = str(self.home)
        spec = importlib.util.spec_from_file_location("ptb", self.home / "ptb.py")
        self.ptb = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ptb)
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "google-sync"))
        from test_google_sync import FakeGoogle, save
        self.google = FakeGoogle()
        self.save = save
        self.patch = patch.object(self.ptb.cloud, "Google", lambda directory: self.google)
        self.patch.start()
        (self.ptb.state_dir() / "credentials.json").write_text("{}")  # signed in (the fake ignores it)

    def tearDown(self):
        self.patch.stop()
        os.environ.pop("PTB_HOME", None)
        for name in ("google_sync", "ptb_collect"):
            sys.modules.pop(name, None)
        self.temp.cleanup()

    def run_cli(self, *argv, platform="linux"):
        out = io.StringIO()
        with patch.object(sys, "argv", ["ptb", *argv]), patch.object(self.ptb.sys, "platform", platform), \
                contextlib.redirect_stdout(out):
            self.ptb.main()
        return out.getvalue()

    def claude_log(self, tokens, message_id="m1"):
        root = Path(self.temp.name) / "claude" / "proj"
        root.mkdir(parents=True, exist_ok=True)
        line = {"type": "assistant", "timestamp": "2026-11-13T03:00:00Z", "requestId": "r-" + message_id,
                "message": {"id": message_id, "usage": {"input_tokens": tokens, "output_tokens": 0}}}
        with (root / "s.jsonl").open("a") as f:
            f.write(json.dumps(line) + "\n")
        return root.parent

    def test_push_uploads_daily_totals_and_updates_the_same_file(self):
        root = self.claude_log(100)
        self.ptb.save_config({"timezone": "Asia/Seoul", "deviceName": "parkes-server", "claudeRoots": [str(root)]})
        self.run_cli("push")
        self.claude_log(50, "m2")
        self.run_cli("push", "--quiet")
        files = [(m, v) for m, v in self.google.store.values() if m["appProperties"]["ptbKind"] == "usage-v1"]
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0][0]["name"], "PokeTokenBar-Usage-parkes-server.json")
        self.assertEqual(files[0][1]["days"], {"2026-11-13": {"claude": 150}})

    def test_push_refuses_on_a_mac_running_the_app(self):
        root = self.claude_log(1)
        self.ptb.save_config({"claudeRoots": [str(root)]})
        with self.assertRaises(self.ptb.cloud.SyncError):
            self.run_cli("push", platform="darwin")
        self.assertEqual(self.google.store, {}, "nothing uploaded, so the Mac's usage is not counted twice")

    def test_commands_explain_how_to_sign_in_first(self):
        (self.ptb.state_dir() / "credentials.json").unlink()
        for command in ("push", "status", "dex"):
            with self.assertRaises(self.ptb.cloud.SyncError) as error:
                self.run_cli(command)
            self.assertIn("ptb login", str(error.exception), command)

    def test_push_never_writes_a_save(self):
        root = self.claude_log(1)
        self.ptb.save_config({"claudeRoots": [str(root)]})
        self.run_cli("push")
        self.assertFalse(any(m["appProperties"]["ptbKind"] == "save-v1" for m, _ in self.google.store.values()))

    def mac_save(self):
        state = self.save(5000)["state"]
        state.update(spentTokens=1000, inventory={"candy": 3, "mint": 0},
                     active={"baseID": 1, "pathIDs": [1, 2, 3], "stageIndex": 1, "usedAtStage": 42,
                             "rarity": "rare", "isShiny": True},
                     dex=[{"baseID": 4, "finalID": 6, "chainOrder": [4, 5, 6], "rarity": "common",
                           "names": [4, {"en": "Charmander"}, 5, {"en": "Charmeleon"}, 6, {"en": "Charizard"},
                                     2, {"en": "Ivysaur"}]}])
        sync = self.ptb.cloud.Sync(self.google, Path(self.temp.name) / "mac")
        sync.exchange(dict(self.save(), state=state), "local")

    def test_status_reads_the_latest_save(self):
        self.mac_save()
        out = self.run_cli("status", "--lang", "en")
        self.assertIn("Companion: Ivysaur ✨ · rare · stage 2/3 · 42 tokens", out)
        self.assertIn("Tokens: 5,000 total · 4,000 to spend", out)
        self.assertIn("Items: candy ×3", out)
        self.assertNotIn("mint", out)

    def test_dex_lists_chains_with_saved_names(self):
        self.mac_save()
        out = self.run_cli("dex", "--lang", "en")
        self.assertIn("Charmander → Charmeleon → Charizard", out)
        self.assertIn("1 records · 1 species · 0 shiny", out)

    def test_status_without_a_save_explains_what_to_do(self):
        with self.assertRaises(self.ptb.cloud.SyncError) as error:
            self.run_cli("status")
        self.assertIn("Mac app", str(error.exception))

    def test_install_replaces_its_own_cron_line_and_keeps_others(self):
        crontab = {"text": "0 1 * * * backup.sh\n"}

        def fake_run(argv, input=None, **kwargs):
            if argv == ["crontab", "-l"]:
                return subprocess.CompletedProcess(argv, 0, crontab["text"], "")
            crontab["text"] = input
            return subprocess.CompletedProcess(argv, 0, "", "")

        fake_home = Path(self.temp.name) / "home"
        with patch.object(self.ptb.subprocess, "run", fake_run), patch.dict(os.environ, {"HOME": str(fake_home)}):
            self.run_cli("install", "--name", "parkes-server")
            self.run_cli("install", "--interval", "15")
        lines = crontab["text"].strip().splitlines()
        self.assertEqual(lines[0], "0 1 * * * backup.sh")
        self.assertEqual(sum(self.ptb.CRON_MARK in l for l in lines), 1)
        self.assertTrue(lines[1].startswith("*/15 "))
        self.assertTrue((fake_home / ".local/bin/ptb").exists())
        self.assertEqual(self.ptb.config()["deviceName"], "parkes-server")


if __name__ == "__main__":
    unittest.main()
