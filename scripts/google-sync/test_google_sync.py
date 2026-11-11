import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.request
import uuid

SCRIPT = Path(__file__).resolve().parents[2] / "Sources/PokeTokenBar/Resources/CloudSync/google_sync.py"
spec = importlib.util.spec_from_file_location("google_sync", SCRIPT)
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)


def save(tokens=10):
    return {"format": "poketokenbar.save", "schema": 2, "appVersion": "test",
            "sourceDevice": "Test Mac", "exportedAt": "2026-11-09T00:00:00Z",
            "state": {"usedSinceInstall": tokens, "spentTokens": 0,
                      "inventory": {"candy": 1}}}


class FakeGoogle:
    def __init__(self):
        self.account = {"sub": "google-account-1", "email": "test@example.invalid"}
        self.credentials = {"client_id": "client.apps.googleusercontent.com"}
        self.store = {}
        self.fail_after_create = False
        self.requests = []

    def files(self, kind):
        return [dict(copy.deepcopy(meta), id=key) for key, (meta, _) in self.store.items()
                if meta["appProperties"]["ptbKind"] == kind and not meta.get("trashed")]

    def create(self, metadata, value):
        key = str(uuid.uuid4())
        self.store[key] = (copy.deepcopy(metadata), copy.deepcopy(value))
        if self.fail_after_create:
            self.fail_after_create = False
            raise cloud.SyncError("connection lost after commit")
        return key

    def download(self, key, maximum=cloud.MAX_SAVE):
        return copy.deepcopy(self.store[key][1])

    def request(self, url, method, value=None):
        self.requests.append((url, method, copy.deepcopy(value)))
        key = urllib.parse.urlparse(url).path.rsplit("/", 1)[1]
        if method == "DELETE":
            self.store.pop(key, None)
        elif method == "PATCH":
            if url.startswith(cloud.UPLOAD):
                self.store[key] = (self.store[key][0], copy.deepcopy(value))
            else:
                self.store[key][0].update(value)
        else:
            raise AssertionError(method)
        return b""


class GoogleSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.google = FakeGoogle()
        self.a = cloud.Sync(self.google, self.directory / "a")
        self.b = cloud.Sync(self.google, self.directory / "b")

    def tearDown(self):
        self.temp.cleanup()

    def adopt(self, client, local):
        inspect = client.exchange(local)
        result = client.exchange(local, "remote", inspect["heads"][0]["revision"])
        client.acknowledge(result["clock"], result["digest"])
        return result["save"]

    def test_first_sync_automatically_backs_up_and_device_only_fields_do_not_upload(self):
        self.assertEqual(self.a.exchange(save())["status"], "uploaded")
        self.assertEqual(len(self.google.store), 1)
        local = save()
        local["exportedAt"] = "2026-11-09T10:00:00Z"
        local["state"].update(language="ko", lastDate="another-day", claimedTodayTokensByProvider={"local": 123})
        self.assertEqual(self.a.exchange(local)["status"], "unchanged")
        self.assertEqual(len(self.google.store), 1)

    def test_game_difficulty_is_part_of_synced_progress(self):
        initial = save()
        initial["gameSettings"] = {"growthDifficulty": 1, "shopDifficulty": 1}
        self.a.exchange(initial, "local")
        changed = copy.deepcopy(initial)
        changed["gameSettings"]["growthDifficulty"] = 0.5
        self.assertEqual(self.a.exchange(changed)["status"], "uploaded")

    def test_set_encoding_order_does_not_create_a_false_game_edit(self):
        initial = save()
        initial["state"]["collectedFinals"] = ["a", "b"]
        initial["state"]["notifiedDexCompletions"] = ["kanto", "johto"]
        self.a.exchange(initial, "local")
        reordered = copy.deepcopy(initial)
        reordered["state"]["collectedFinals"].reverse()
        reordered["state"]["notifiedDexCompletions"].reverse()
        self.assertEqual(self.a.exchange(reordered)["status"], "unchanged")

    def test_sequential_handoff(self):
        self.a.exchange(save(100), "local")
        self.assertEqual(self.b.exchange(save(0))["status"], "choose")
        current = self.adopt(self.b, save(0))
        self.assertEqual(current["state"]["usedSinceInstall"], 100)
        self.a.exchange(save(200))
        result = self.b.exchange(current)
        self.assertEqual(result["status"], "download")
        self.assertEqual(result["save"]["state"]["usedSinceInstall"], 200)
        self.b.acknowledge(result["clock"], result["digest"])
        self.assertEqual(self.b.exchange(result["save"])["status"], "unchanged")

    def test_concurrent_edits_never_merge_inventory_or_overwrite_automatically(self):
        self.a.exchange(save(100), "local")
        self.adopt(self.b, save(0))
        old_records = self.b.records()
        old_clock = copy.deepcopy(self.b.journal["clock"])
        self.a.exchange(save(200))
        # B published from an offline/stale view of the same ancestor.
        self.b.publish(save(300), old_clock, old_records)
        self.assertEqual(len(cloud.heads(self.a.records())), 2)
        before = len(self.google.store)
        self.assertEqual(self.a.exchange(save(200))["status"], "conflict")
        self.assertEqual(len(self.google.store), before)
        self.a.exchange(save(200), "local")
        records = self.a.records()
        self.assertEqual(len(cloud.heads(records)), 1)
        self.assertEqual(len(records), before + 1)  # Both original branches remain available.
        self.assertEqual(self.a.download(cloud.heads(records)[0])["state"]["usedSinceInstall"], 200)

    def test_upload_lost_response_and_new_local_changes_are_recovered_in_order(self):
        self.google.fail_after_create = True
        with self.assertRaises(cloud.SyncError):
            self.a.exchange(save(100), "local")
        self.assertIn("pending", self.a.journal)
        restarted = cloud.Sync(self.google, self.directory / "a")
        self.assertEqual(restarted.exchange(save(200))["status"], "uploaded")
        self.assertEqual(len(self.google.store), 2)
        self.assertEqual(len(cloud.heads(restarted.records())), 1)
        self.assertEqual(restarted.journal["clock"][restarted.journal["device"]], 2)

    def test_download_without_ack_retries_import_instead_of_uploading_stale_local(self):
        self.a.exchange(save(100), "local")
        reply = self.b.exchange(save(0), "remote", self.b.exchange(save(0))["heads"][0]["revision"])
        restarted = cloud.Sync(self.google, self.directory / "b")
        retry = restarted.exchange(save(0))
        self.assertEqual(retry["status"], "download")
        self.assertEqual(retry["save"], reply["save"])
        before = len(self.google.store)
        self.assertEqual(restarted.exchange(save(7))["status"], "conflict")
        self.assertEqual(len(self.google.store), before)
        # App applied the imported save, but died before acknowledging it.
        self.assertEqual(restarted.exchange(reply["save"])["status"], "unchanged")
        self.assertNotIn("pendingImport", restarted.journal)

    def test_remote_resolution_commit_lost_response_replays_the_selected_import(self):
        self.a.exchange(save(100), "local")
        head = self.b.exchange(save(0))["heads"][0]["revision"]
        self.b.publish(save(0), {}, [])  # A genuinely concurrent cloud branch must be resolved.
        self.google.fail_after_create = True
        with self.assertRaises(cloud.SyncError):
            self.b.exchange(save(0), "remote", head)
        restarted = cloud.Sync(self.google, self.directory / "b")
        reply = restarted.exchange(save(0))
        self.assertEqual(reply["status"], "download")
        self.assertEqual(reply["save"]["state"]["usedSinceInstall"], 100)

    def test_same_clock_different_revisions_remain_a_conflict(self):
        self.a.exchange(save(100), "local")
        records = self.a.records()
        metadata = copy.deepcopy(next(iter(self.google.store.values()))[0])
        meta = json.loads(metadata["description"])
        meta["revision"] = str(uuid.uuid4())
        metadata["description"] = json.dumps(meta)
        self.google.create(metadata, save(100))
        self.assertEqual(len(cloud.heads(self.a.records())), 2)
        self.assertEqual(self.a.exchange(save(100))["status"], "conflict")

    def test_corrupt_remote_content_and_forged_ack_are_rejected(self):
        self.a.exchange(save(100), "local")
        item = next(iter(self.google.store.values()))
        item[1]["state"]["usedSinceInstall"] = 999
        head = self.b.exchange(save(0))["heads"][0]["revision"]
        with self.assertRaisesRegex(cloud.SyncError, "digest mismatch"):
            self.b.exchange(save(0), "remote", head)
        with self.assertRaises(cloud.SyncError):
            self.b.acknowledge({}, "invented")

    def test_account_and_client_namespaces_do_not_share_revision_journals(self):
        self.a.exchange(save(), "local")
        self.google.account = {"sub": "different-account", "email": "other@example.invalid"}
        other = cloud.Sync(self.google, self.directory / "a")
        self.assertNotEqual(other.journal_path, self.a.journal_path)
        self.assertIsNone(other.journal["digest"])

    def test_own_dominated_history_is_bounded_and_other_devices_are_preserved(self):
        self.a.exchange(save(0), "local")
        self.adopt(self.b, save(1000))
        b_files = {r["fileId"] for r in self.b.records() if r["writer"] == self.b.journal["device"]}
        # Synchronize back before producing many revisions on A.
        cloud_heads = cloud.heads(self.a.records())
        reply = self.a.exchange(save(0), "remote", cloud_heads[0]["revision"])
        self.a.acknowledge(reply["clock"], reply["digest"])
        for n in range(1, 40):
            self.a.exchange(save(n))
        own = [r for r in self.a.records() if r["writer"] == self.a.journal["device"]]
        self.assertLessEqual(len(own), 30)
        self.assertTrue(b_files.issubset(set(self.google.store)))
        self.assertTrue(any(meta.get("trashed") for meta, _ in self.google.store.values()))
        self.assertFalse(any(method == "DELETE" for _, method, _ in self.google.requests))

    def test_clock_validation_rejects_boolean_and_invalid_identity(self):
        for value in [{"bad": 1}, {str(uuid.uuid4()): True}, [], {str(uuid.uuid4()): -1}]:
            with self.assertRaises(cloud.SyncError):
                cloud.clock(value)

    def test_google_login_uses_pkce_validated_state_and_private_credentials(self):
        client = self.directory / "desktop.json"
        client.write_text(json.dumps({"installed": {"client_id": "test.apps.googleusercontent.com",
                                                  "client_secret": "desktop-public-config"}}))
        observed = {}

        def browser(url):
            parsed = urllib.parse.urlparse(url)
            self.assertEqual(parsed.hostname, "accounts.google.com")
            query = urllib.parse.parse_qs(parsed.query)
            observed.update({k: v[0] for k, v in query.items()})
            valid = urllib.parse.urlencode({"code": "test-code", "state": observed["state"]})
            observed["callbacks"] = ["/oauth2callback?code=wrong&state=wrong", "/oauth2callback?" + valid]
            return True

        # The execution sandbox cannot bind loopback sockets. Drive the production
        # handler through an in-process HTTP transport instead; no live login is claimed.
        class CallbackTransport:
            def __init__(self, address, handler):
                self.server_port, self.handler = 34567, handler
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def handle_request(self):
                instance = self.handler.__new__(self.handler)
                instance.path = observed["callbacks"].pop(0)
                instance.headers = {"Host": "127.0.0.1:34567"}
                instance.server = self
                instance.wfile = io.BytesIO()
                instance.send_response = lambda code: observed.setdefault("responses", []).append(code)
                instance.send_header = lambda *args: None
                instance.end_headers = lambda: None
                instance.do_GET()

        def request(url, method="GET", body=None, headers=None, maximum=None):
            if url == cloud.TOKEN:
                fields = urllib.parse.parse_qs(body.decode())
                verifier = fields["code_verifier"][0]
                challenge = cloud.base64.urlsafe_b64encode(cloud.hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                self.assertEqual(challenge, observed["code_challenge"])
                self.assertEqual(observed["code_challenge_method"], "S256")
                self.assertEqual(fields["code"][0], "test-code")
                return cloud.encode({"access_token": "fake-access", "refresh_token": "fake-refresh",
                                     "scope": observed.get("granted_scopes", cloud.SCOPES)})
            return cloud.encode({"sub": "account", "email": "test@example.invalid", "email_verified": True})

        with patch.object(cloud.webbrowser, "open", browser), patch.object(cloud.Google, "raw", request), \
                patch.object(cloud.http.server, "HTTPServer", CallbackTransport):
            reply = cloud.authorize(self.directory / "auth", client)
        self.assertEqual(observed["responses"], [400, 200])
        self.assertEqual(reply["status"], "connected")
        credential = self.directory / "auth/credentials.json"
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fake-refresh", json.dumps(reply))
        observed["granted_scopes"] = "openid email"
        with patch.object(cloud.webbrowser, "open", browser), patch.object(cloud.Google, "raw", request), \
                patch.object(cloud.http.server, "HTTPServer", CallbackTransport):
            with self.assertRaisesRegex(cloud.SyncError, "permission was not granted"):
                cloud.authorize(self.directory / "denied", client)
        self.assertFalse((self.directory / "denied/credentials.json").exists())


class SignInWindowTest(unittest.TestCase):
    def test_listener_waits_the_full_window_then_reports_a_timeout(self):
        clock = {"now": 0.0, "requests": 0}

        class IdleServer:
            server_port = 53126
            timeout = None

            def __init__(self, *args):
                pass

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def handle_request(self):
                clock["requests"] += 1
                clock["now"] += 60  # the browser never comes back

        with tempfile.TemporaryDirectory() as directory:
            client = Path(directory) / "client.json"
            client.write_text(json.dumps({"installed": {"client_id": "test.apps.googleusercontent.com"}}))
            with patch.object(cloud.http.server, "HTTPServer", IdleServer), \
                    patch.object(cloud.webbrowser, "open", lambda url: True), \
                    patch.object(cloud.time, "monotonic", lambda: clock["now"]):
                with self.assertRaisesRegex(cloud.SyncError, "timed out after 10 minutes"):
                    cloud.authorize(Path(directory) / "auth", client)
        self.assertGreaterEqual(cloud.SIGN_IN_WINDOW_SECONDS, 600)
        self.assertEqual(clock["requests"], cloud.SIGN_IN_WINDOW_SECONDS // 60)


class FolderTransport(cloud.Google):
    """Exercise the real folder/list/multipart code without network or account credentials."""
    def __init__(self, folders=()):
        self._folder_ids = None
        self.folders = copy.deepcopy(list(folders))
        self.calls = []

    def request(self, url, method="GET", value=None, body=None, content_type=None, maximum=None):
        self.calls.append((url, method, copy.deepcopy(value), body))
        if method == "POST" and url.startswith(cloud.API):
            result = {"id": "new-private-folder", "name": cloud.FOLDER_NAME,
                      "createdTime": "2026-11-10T00:00:00Z", "ownedByMe": True, "shared": False}
            self.folders.append(result)
            return cloud.encode(result)
        if method == "POST" and url.startswith(cloud.UPLOAD):
            return cloud.encode({"id": "new-save"})
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("q", [""])[0]
        if "mimeType" in query:
            return cloud.encode({"files": self.folders})
        return cloud.encode({"files": []})


class DriveFolderSecurityTests(unittest.TestCase):
    def folder(self, id="existing-folder", **changes):
        return dict({"id": id, "name": cloud.FOLDER_NAME, "createdTime": "2026-01-01T00:00:00Z",
                     "ownedByMe": True, "shared": False}, **changes)

    def test_creates_private_folder_at_my_drive_root_and_scopes_all_record_queries(self):
        google = FolderTransport()
        self.assertEqual(google.folder_ids(), ["new-private-folder"])
        created = next(value for _, method, value, _ in google.calls if method == "POST")
        self.assertEqual(created["name"], "PokeTokenBar_Save")
        self.assertEqual(created["parents"], ["root"])
        self.assertEqual(created["mimeType"], "application/vnd.google-apps.folder")
        google.files("save-v1")
        url = google.calls[-1][0]
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        self.assertEqual(query["spaces"], ["drive"])
        self.assertIn("'new-private-folder' in parents", query["q"][0])
        self.assertNotIn("appDataFolder", url)

    def test_reuses_existing_folder_and_uploads_only_inside_it(self):
        google = FolderTransport([self.folder()])
        self.assertEqual(google.folder_ids(), ["existing-folder"])
        self.assertFalse(any(method == "POST" for _, method, _, _ in google.calls))
        google.create({"name": "save.json", "parents": ["outside-folder"]}, save())
        body = google.calls[-1][3]
        raw = body.split(b"\r\n\r\n", 1)[1].split(b"\r\n--", 1)[0]
        self.assertEqual(json.loads(raw)["parents"], ["existing-folder"])
        self.assertNotIn(b"outside-folder", body)
        self.assertEqual(google.folder_url(), "https://drive.google.com/drive/folders/existing-folder")

    def test_shared_other_owned_or_shared_drive_folders_are_rejected(self):
        for changes in ({"shared": True}, {"ownedByMe": False}, {"driveId": "shared-drive"}):
            google = FolderTransport([self.folder(**changes)])
            with self.assertRaisesRegex(cloud.SyncError, "private folder"):
                google.folder_ids()
            self.assertFalse(any(method == "POST" for _, method, _, _ in google.calls))

    def test_duplicate_roots_are_all_read_but_only_canonical_root_is_written(self):
        google = FolderTransport([self.folder("later", createdTime="2026-11-10T00:00:00Z"), self.folder("older")])
        self.assertEqual(google.folder_ids(), ["older", "later"])
        google.files("save-v1")
        query = urllib.parse.parse_qs(urllib.parse.urlparse(google.calls[-1][0]).query)["q"][0]
        self.assertIn("'older' in parents", query)
        self.assertIn("'later' in parents", query)

    def test_bearer_requests_cannot_target_other_hosts_or_follow_redirects(self):
        for url in ("http://www.googleapis.com/drive/v3/files", "https://attacker.invalid/",
                    "https://www.googleapis.com.attacker.invalid/", "https://token@www.googleapis.com/"):
            with self.assertRaises(cloud.SyncError):
                cloud.Google.raw(url, headers={"Authorization": "Bearer private-token"})
        with self.assertRaises(cloud.SyncError):
            cloud.NoRedirect().redirect_request(None, None, 302, "redirect", {}, "https://attacker.invalid/")

    def test_old_hidden_folder_permission_requires_new_consent(self):
        with tempfile.TemporaryDirectory() as folder:
            cloud.atomic_json(Path(folder) / "credentials.json", {"account": {"sub": "test"},
                "scopes": ["https://www.googleapis.com/auth/drive.appdata"]})
            with self.assertRaisesRegex(cloud.SyncError, "Sign in again"):
                cloud.Google(folder)
        self.assertIn(cloud.DRIVE_SCOPE, cloud.SCOPES.split())
        self.assertNotIn("https://www.googleapis.com/auth/drive", cloud.SCOPES.split())

    def test_credentials_cannot_be_group_readable_or_a_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "credentials.json"
            cloud.atomic_json(path, {"account": {"sub": "test"}, "scopes": [cloud.DRIVE_SCOPE]})
            os.chmod(path, 0o644)
            with self.assertRaisesRegex(cloud.SyncError, "private regular file"):
                cloud.Google(folder)
            alias = Path(folder) / "directory-alias"
            alias.symlink_to(Path(folder), target_is_directory=True)
            with self.assertRaisesRegex(cloud.SyncError, "real directory"):
                cloud.private_directory(alias)
            target = Path(folder) / "private.json"
            path.rename(target)
            os.chmod(target, 0o600)
            path.symlink_to(target)
            with self.assertRaisesRegex(cloud.SyncError, "private regular file"):
                cloud.Google(folder)


if __name__ == "__main__":
    unittest.main()
