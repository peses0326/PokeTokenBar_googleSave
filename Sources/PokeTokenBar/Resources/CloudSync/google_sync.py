#!/usr/bin/env python3
"""Personal Google Drive PokeTokenBar_Save folder sync. Python 3.9+, stdlib only.

Each game revision is immutable. Vector clocks detect concurrent/offline edits;
no timestamp-based last-writer-wins or JSON merging is used for game saves.
"""
import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import secrets
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser

DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
SCOPES = "openid email " + DRIVE_SCOPE
FOLDER_NAME = "PokeTokenBar_Save"
API = "https://www.googleapis.com/drive/v3/files"
UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
TOKEN = "https://oauth2.googleapis.com/token"
MAX_SAVE = 8 * 1024 * 1024
MAX_SUMMARY = 256 * 1024
MAX_FILES = 2000
# How long the loopback listener waits for the browser. The consent screen, the unverified-app
# warning and adding a test user can easily take longer than 4 minutes; when the listener has
# already exited, the browser only shows "127.0.0.1 refused to connect". GoogleCloudSync.swift
# waits a little longer than this (signInWindow) so it never kills the helper first.
SIGN_IN_WINDOW_SECONDS = 600


class SyncError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        raise SyncError("Unexpected Google redirect was blocked; no authorization token was forwarded")


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(path.name + "." + secrets.token_hex(8))
    try:
        with temporary.open("xb") as stream:
            os.chmod(temporary, 0o600)
            stream.write(encode(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temporary.unlink()


def read_json(path, maximum=MAX_SAVE):
    with Path(path).open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise SyncError("Local JSON exceeds its size limit")
    return json.loads(data)


def private_directory(path):
    path = Path(path).expanduser()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise SyncError("Google sync directory must be a real directory owned by you")
    os.chmod(path, 0o700)
    return path


def valid_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except ValueError:
        return False


def clock(value):
    if not isinstance(value, dict) or len(value) > 64:
        raise SyncError("Invalid revision clock")
    if not all(valid_uuid(k) and type(v) is int and 0 < v < 2**53 for k, v in value.items()):
        raise SyncError("Invalid revision clock entry")
    return value


def dominates(a, b):
    return all(a.get(k, 0) >= v for k, v in b.items())


def merge_clocks(values):
    result = {}
    for value in values:
        for key, sequence in clock(value).items():
            result[key] = max(result.get(key, 0), sequence)
    return result


def heads(records):
    # Equal clocks with different revision IDs remain a conflict, never an arbitrary winner.
    return [r for r in records if not any(
        other["revision"] != r["revision"] and other["clock"] != r["clock"] and
        dominates(other["clock"], r["clock"]) for other in records)]


def save_digest(save):
    # Device-local daily baselines and display language are intentionally not shared game edits.
    value = json.loads(json.dumps(save["state"]))
    for key in ("claimedTodayTokensByProvider", "lastDate", "installBaselineSet", "language"):
        value.pop(key, None)
    for key in ("collectedFinals", "notifiedDexCompletions"):
        if isinstance(value.get(key), list) and all(isinstance(v, str) for v in value[key]):
            value[key] = sorted(value[key])  # Swift Set order differs between processes.
    return hashlib.sha256(encode({"state": value, "gameSettings": save.get("gameSettings")})).hexdigest()


def validate_save(save):
    if not isinstance(save, dict) or save.get("format") != "poketokenbar.save" or \
            type(save.get("schema")) is not int or not 1 <= save["schema"] <= 2 or \
            not isinstance(save.get("state"), dict) or len(encode(save)) > MAX_SAVE:
        raise SyncError("Invalid or unsupported game save")
    return save


class Google:
    def __init__(self, directory):
        self.directory = private_directory(directory)
        self.credentials_path = self.directory / "credentials.json"
        attributes = self.credentials_path.lstat()
        if not stat.S_ISREG(attributes.st_mode) or attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
            raise SyncError("Google credential file must be a private regular file owned by you; reconnect or fix its permissions")
        self.credentials = read_json(self.credentials_path, MAX_SUMMARY)
        self.account = self.credentials["account"]
        if not isinstance(self.account.get("sub"), str):
            raise SyncError("Google account identity missing; sign in again")
        if DRIVE_SCOPE not in self.credentials.get("scopes", []):
            raise SyncError("Sign in again to allow saving in your PokeTokenBar_Save Drive folder")
        self._folder_ids = None

    @staticmethod
    def raw(url, method="GET", body=None, headers=None, maximum=MAX_SAVE + 65536):
        destination = urllib.parse.urlparse(url)
        if destination.scheme != "https" or destination.hostname not in {
                "www.googleapis.com", "oauth2.googleapis.com", "openidconnect.googleapis.com"} or \
                destination.port not in (None, 443) or destination.username or destination.password:
            raise SyncError("Google API destination is not allowed")
        request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
            data = response.read(maximum + 1)
            if len(data) > maximum:
                raise SyncError("Google response exceeds its size limit")
            return data

    def refresh(self):
        fields = {"client_id": self.credentials["client_id"],
                  "refresh_token": self.credentials["refresh_token"], "grant_type": "refresh_token"}
        if self.credentials.get("client_secret"):
            fields["client_secret"] = self.credentials["client_secret"]
        try:
            token = json.loads(self.raw(TOKEN, "POST", urllib.parse.urlencode(fields).encode(),
                {"Content-Type": "application/x-www-form-urlencoded"}, MAX_SUMMARY))
        except urllib.error.HTTPError as error:
            raise SyncError(f"Google sign-in expired or rejected (HTTP {error.code}); sign in again") from None
        self.credentials["access_token"] = token["access_token"]
        self.credentials["expires_at"] = time.time() + int(token.get("expires_in", 3600))
        if token.get("refresh_token"):
            self.credentials["refresh_token"] = token["refresh_token"]
        atomic_json(self.credentials_path, self.credentials)

    def request(self, url, method="GET", value=None, body=None, content_type=None, maximum=MAX_SAVE + 65536):
        if self.credentials.get("expires_at", 0) <= time.time() + 60:
            self.refresh()
        if value is not None:
            body, content_type = encode(value), "application/json"
        for attempt in range(2):
            headers = {"Authorization": "Bearer " + self.credentials["access_token"]}
            if content_type:
                headers["Content-Type"] = content_type
            try:
                return self.raw(url, method, body, headers, maximum)
            except urllib.error.HTTPError as error:
                if error.code == 401 and attempt == 0:
                    self.refresh()
                    continue
                raise SyncError(f"Google Drive request failed (HTTP {error.code})") from None

    def files(self, kind):
        parents = " or ".join("'" + value + "' in parents" for value in self.folder_ids())
        token, result = None, []
        while True:
            params = {"spaces": "drive", "pageSize": "1000",
                "q": "trashed = false and (" + parents + ") and appProperties has { key='ptbKind' and value='" + kind + "' }",
                "fields": "nextPageToken,files(id,name,description,appProperties)"}
            if token:
                params["pageToken"] = token
            page = json.loads(self.request(API + "?" + urllib.parse.urlencode(params), maximum=2 * 1024 * 1024))
            result.extend(page.get("files", []))
            if len(result) > MAX_FILES:
                raise SyncError("Too many cloud records; archive old device revisions before syncing")
            token = page.get("nextPageToken")
            if not token:
                return result

    def folder_ids(self):
        if self._folder_ids is not None:
            return self._folder_ids
        def find_folders():
            result, token = [], None
            while True:
                params = {"spaces": "drive", "pageSize": "100", "fields": "nextPageToken,files(id,name,createdTime,ownedByMe,shared,driveId)",
                    "q": "trashed = false and 'root' in parents and mimeType = 'application/vnd.google-apps.folder' and name = '" + FOLDER_NAME + "'"}
                if token:
                    params["pageToken"] = token
                page = json.loads(self.request(API + "?" + urllib.parse.urlencode(params), maximum=MAX_SUMMARY))
                result.extend(page.get("files", []))
                if len(result) > 32:
                    raise SyncError("Too many PokeTokenBar_Save folders; consolidate the duplicate folders in Drive")
                token = page.get("nextPageToken")
                if not token:
                    return result
        folders = find_folders()
        if not folders:
            created = json.loads(self.request(API + "?fields=id,name,createdTime,ownedByMe,shared,driveId", "POST", value={
                "name": FOLDER_NAME, "mimeType": "application/vnd.google-apps.folder", "parents": ["root"],
                "appProperties": {"ptbRole": "save-root-v1"}}))
            # Two devices may create the folder together. Read all matching app-accessible
            # roots so no branch disappears; only the oldest folder receives new files.
            folders = find_folders()
            if not any(item.get("id") == created.get("id") for item in folders):
                folders.append(created)
        folders.sort(key=lambda item: (item.get("createdTime", ""), item["id"]))
        if any(item.get("ownedByMe") is not True or item.get("shared") or item.get("driveId") for item in folders):
            raise SyncError("PokeTokenBar_Save must be a private folder owned by your Google account; check Drive sharing settings")
        ids = [item["id"] for item in folders]
        if not ids or any(not isinstance(value, str) or not value or "'" in value for value in ids):
            raise SyncError("Invalid Google Drive folder ID")
        self._folder_ids = list(dict.fromkeys(ids))
        return self._folder_ids

    def folder_url(self):
        return "https://drive.google.com/drive/folders/" + urllib.parse.quote(self.folder_ids()[0], safe="")

    def create(self, metadata, value):
        metadata = dict(metadata, parents=[self.folder_ids()[0]])
        boundary = "ptb_" + secrets.token_hex(16)
        body = (f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode() +
                encode(metadata) + f"\r\n--{boundary}\r\nContent-Type: application/json\r\n\r\n".encode() +
                encode(value) + f"\r\n--{boundary}--\r\n".encode())
        return json.loads(self.request(UPLOAD + "?uploadType=multipart&fields=id", "POST", body=body,
                                      content_type="multipart/related; boundary=" + boundary))["id"]

    def download(self, file_id, maximum=MAX_SAVE + 65536):
        return json.loads(self.request(API + "/" + urllib.parse.quote(file_id, safe="") + "?alt=media",
                                       maximum=maximum))


def authorize(directory, client_path, port=0, no_browser=False):
    directory = private_directory(directory)
    config = read_json(client_path, MAX_SUMMARY).get("installed")
    if not isinstance(config, dict) or not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", str(config.get("client_id", ""))):
        raise SyncError("Select a Google OAuth Desktop app JSON (installed client)")
    verifier, state = secrets.token_urlsafe(64), secrets.token_urlsafe(32)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    outcome = {}

    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Never log authorization codes or callback URLs.

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            valid = parsed.path == "/oauth2callback" and len(query.get("state", [])) == 1 and \
                secrets.compare_digest(query["state"][0], state)
            valid = valid and self.headers.get("Host") == f"127.0.0.1:{self.server.server_port}"
            if not valid:
                self.send_response(400); self.end_headers(); return
            if len(query.get("code", [])) == 1:
                outcome["code"] = query["code"][0]
            else:
                outcome["error"] = "Google login was cancelled or rejected"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b"Sign-in received. You can close this tab and return to PokeTokenBar.")

    with http.server.HTTPServer(("127.0.0.1", port), Callback) as server:
        server.timeout = 1
        redirect = f"http://127.0.0.1:{server.server_port}/oauth2callback"
        params = {"client_id": config["client_id"], "redirect_uri": redirect, "response_type": "code",
                  "scope": SCOPES, "state": state, "code_challenge": challenge,
                  "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"}
        url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params)
        if no_browser:
            print("Open this URL in your browser (forward the loopback port for a remote host):\n" + url, file=sys.stderr)
        elif not webbrowser.open(url):
            raise SyncError("Could not open the system browser")
        deadline = time.monotonic() + SIGN_IN_WINDOW_SECONDS
        while not outcome and time.monotonic() < deadline:
            server.handle_request()
        if "code" not in outcome:
            raise SyncError(outcome.get("error", "Google sign-in timed out after 10 minutes. Start sign-in again and finish it in the browser."))
    fields = {"client_id": config["client_id"],
              "code": outcome["code"], "code_verifier": verifier, "redirect_uri": redirect,
              "grant_type": "authorization_code"}
    if config.get("client_secret"):
        fields["client_secret"] = config["client_secret"]
    try:
        token = json.loads(Google.raw(TOKEN, "POST", urllib.parse.urlencode(fields).encode(),
                          {"Content-Type": "application/x-www-form-urlencoded"}, MAX_SUMMARY))
        account = json.loads(Google.raw("https://openidconnect.googleapis.com/v1/userinfo", headers={
            "Authorization": "Bearer " + token["access_token"]}, maximum=MAX_SUMMARY))
    except urllib.error.HTTPError as error:
        raise SyncError(f"Google sign-in failed (HTTP {error.code})") from None
    if not token.get("refresh_token") or not account.get("sub") or account.get("email_verified") is not True:
        raise SyncError("Google did not grant offline access and a verified account; sign in again")
    granted = set(token.get("scope", "").split())
    if DRIVE_SCOPE not in granted:
        raise SyncError("Google Drive file permission was not granted")
    credentials = {"client_id": config["client_id"], "client_secret": config.get("client_secret", ""),
        "refresh_token": token["refresh_token"], "access_token": token["access_token"],
        "expires_at": time.time() + int(token.get("expires_in", 3600)),
        "scopes": sorted(granted),
        "account": {"sub": account["sub"], "email": account.get("email", "")}}
    atomic_json(Path(directory) / "credentials.json", credentials)
    return {"status": "connected", "account": credentials["account"]}


class Sync:
    def __init__(self, google, directory):
        self.google = google
        self.directory = Path(directory)
        namespace = hashlib.sha256(encode([google.account["sub"], google.credentials["client_id"]])).hexdigest()
        self.journal_path = self.directory / ("journal-" + namespace + ".json")
        if self.journal_path.exists():
            self.journal = read_json(self.journal_path, MAX_SAVE + 65536)
        else:
            self.journal = {"device": str(uuid.uuid4()), "clock": {}, "digest": None}
            atomic_json(self.journal_path, self.journal)

    def records(self):
        unique = {}
        for item in self.google.files("save-v1"):
            try:
                meta = json.loads(item["description"])
                if not valid_uuid(meta["revision"]) or not valid_uuid(meta["writer"]):
                    raise SyncError("Invalid cloud revision identifier")
                clock(meta["clock"])
                if len(meta["sha256"]) != 64:
                    raise SyncError("Invalid cloud revision digest")
                previous = unique.get(meta["revision"])
                if previous and any(previous[k] != meta[k] for k in ("clock", "writer", "sha256")):
                    raise SyncError("Conflicting copies of the same cloud revision")
                unique[meta["revision"]] = dict(meta, fileId=item["id"])
            except (KeyError, TypeError, ValueError):
                raise SyncError("Malformed cloud revision metadata") from None
        return list(unique.values())

    def download(self, record):
        value = self.google.download(record["fileId"])
        if hashlib.sha256(encode(value)).hexdigest() != record["sha256"]:
            raise SyncError("Cloud save digest mismatch")
        return validate_save(value)

    def finish_pending(self, records):
        pending = self.journal.get("pending")
        if not pending:
            return
        if not any(r["revision"] == pending["revision"] for r in records):
            stamp = str(pending["save"].get("exportedAt", ""))[:19].replace(":", "").replace("T", "_")
            self.google.create({"name": "PokeTokenBar-Save-" + stamp + "-" + pending["revision"][:8] + ".json",
                "appProperties": {"ptbKind": "save-v1"},
                "description": json.dumps(dict({k: pending[k] for k in ("revision", "clock", "writer", "sha256")},
                    gameDigest=pending["digest"],
                    deviceName=str(pending["save"].get("sourceDevice", "Device"))[:80],
                    savedAt=pending["save"].get("exportedAt", "")))}, pending["save"])
        self.journal.update(clock=pending["clock"], digest=pending["digest"])
        if "importExpected" in pending:
            self.journal["pendingImport"] = {"clock": pending["clock"], "digest": pending["digest"],
                "expected": pending["importExpected"], "save": pending["save"]}
        self.journal.pop("pending", None)
        atomic_json(self.journal_path, self.journal)

    def publish(self, save, merged, records, import_expected=None):
        device = self.journal["device"]
        merged = merge_clocks([merged, self.journal["clock"]])
        merged[device] = merged.get(device, 0) + 1
        clock(merged)
        digest = save_digest(save)
        pending = {"revision": str(uuid.uuid4()), "clock": merged, "writer": device,
                   "sha256": hashlib.sha256(encode(save)).hexdigest(), "digest": digest, "save": save}
        if import_expected is not None:
            pending["importExpected"] = import_expected
        self.journal["pending"] = pending
        atomic_json(self.journal_path, self.journal)  # Durable payload before network I/O.
        self.finish_pending(records)
        # Only prune this writer's dominated history, retaining 30 revisions including
        # the new one. Other devices and unresolved branch heads are never deleted here.
        old = sorted((r for r in records if r["writer"] == device),
                     key=lambda r: r["clock"].get(device, 0), reverse=True)
        for record in old[29:]:
            if dominates(merged, record["clock"]) and merged != record["clock"]:
                with contextlib.suppress(SyncError):
                    self.google.request(API + "/" + urllib.parse.quote(record["fileId"], safe=""),
                                        "PATCH", value={"trashed": True})
        return merged

    def exchange(self, save, resolution=None, selected=None):
        validate_save(save)
        records = self.records()
        if self.journal.get("pending"):
            self.finish_pending(records)
            records = self.records()
        current_heads = heads(records)
        base = clock(self.journal["clock"])
        digest = save_digest(save)
        dirty = digest != self.journal["digest"]
        merged = merge_clocks([r["clock"] for r in current_heads] + [base])
        result = {"account": self.google.account, "heads": [
            {"revision": r["revision"], "writer": r["writer"],
             "label": r.get("deviceName", "Device"), "savedAt": r.get("savedAt", "")} for r in current_heads]}
        pending_import = self.journal.get("pendingImport")
        if pending_import and resolution is None:
            if digest == pending_import["digest"]:
                self.acknowledge(pending_import["clock"], digest)
                base = clock(self.journal["clock"])
                dirty = False
            elif digest == pending_import["expected"]:
                return dict(result, status="download", save=pending_import["save"],
                            clock=pending_import["clock"], digest=pending_import["digest"])
            else:
                return dict(result, status="conflict")
        if resolution == "local":
            self.journal.pop("pendingImport", None)
            self.publish(save, merged, records)
            return dict(result, status="uploaded")
        if resolution == "remote":
            candidates = [r for r in current_heads if r["revision"] == selected]
            if len(candidates) != 1:
                raise SyncError("Selected cloud revision is no longer a current head; sync again")
            remote = self.download(candidates[0])
            revision_clock = self.publish(remote, merged, records, import_expected=digest) if (
                len(current_heads) > 1 or not dominates(candidates[0]["clock"], base)) else candidates[0]["clock"]
            self.journal["pendingImport"] = {"clock": revision_clock, "digest": save_digest(remote),
                                             "expected": digest, "save": remote}
            atomic_json(self.journal_path, self.journal)
            return dict(result, status="download", save=remote, clock=revision_clock,
                        digest=save_digest(remote))
        if not current_heads:
            self.publish(save, base, records)
            return dict(result, status="uploaded")  # Empty Drive folder: back up local progress automatically.
        if len(current_heads) > 1:
            return dict(result, status="conflict")
        known = all(dominates(base, r["clock"]) for r in current_heads)
        if known:
            if dirty:
                self.publish(save, base, records)
            return dict(result, status="uploaded" if dirty else "unchanged")
        if (not dirty and dominates(current_heads[0]["clock"], base)) or current_heads[0].get("gameDigest") == digest:
            remote = self.download(current_heads[0])
            self.journal["pendingImport"] = {"clock": current_heads[0]["clock"], "digest": save_digest(remote),
                                             "expected": digest, "save": remote}
            atomic_json(self.journal_path, self.journal)
            return dict(result, status="download", save=remote, clock=current_heads[0]["clock"],
                        digest=save_digest(remote))
        return dict(result, status="choose" if self.journal["digest"] is None else "conflict")

    def acknowledge(self, revision_clock, digest):
        # Called only after Swift has backed up and successfully applied a downloaded save.
        pending = self.journal.get("pendingImport")
        if not pending or pending["clock"] != revision_clock or pending["digest"] != digest:
            raise SyncError("Import acknowledgement does not match the pending cloud save")
        self.journal.update(clock=clock(revision_clock), digest=digest)
        self.journal.pop("pendingImport", None)
        atomic_json(self.journal_path, self.journal)

    def usage(self):
        result, totals = [], {}
        for item in self.google.files("usage-v1"):
            source = self.google.download(item["id"], MAX_SUMMARY)
            if not isinstance(source, dict) or source.get("version") != 1 or not valid_uuid(source.get("sourceId")):
                raise SyncError("Invalid cloud usage summary")
            # Duplicate creates after an interrupted upload must not double count a source.
            key = source["sourceId"]
            providers = source.get("providers", {})
            total = sum(integer(p.get("totalTokens")) for p in providers.values())
            if key not in totals or total >= totals[key][0]:
                totals[key] = (total, source)
        result = [value[1] for value in totals.values()]
        if len(result) > 32 or len(encode(result)) > 2 * 1024 * 1024:
            raise SyncError("Cloud usage exceeds the supported source/size limit")
        return result

    def upload_usage(self, source):
        if source.get("version") != 1 or not valid_uuid(source.get("sourceId")) or len(encode(source)) > MAX_SUMMARY:
            raise SyncError("Invalid usage summary")
        source_id = source["sourceId"]
        matches = [item for item in self.google.files("usage-v1")
                   if item.get("name") == "PokeTokenBar-Usage-" + source_id + ".json"]
        if matches:
            # Only this collector writes its source. Concurrent collectors must use different states.
            self.google.request(UPLOAD + "/" + urllib.parse.quote(matches[0]["id"], safe="") + "?uploadType=media",
                                "PATCH", value=source)
        else:
            self.google.create({"name": "PokeTokenBar-Usage-" + source_id + ".json",
                                "appProperties": {"ptbKind": "usage-v1"}}, source)


def integer(value):
    if type(value) is not int or not 0 <= value <= 10**15:
        raise SyncError("Invalid usage counter")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    auth = sub.add_parser("authorize")
    auth.add_argument("--client", required=True)
    auth.add_argument("--port", type=int, default=0)
    auth.add_argument("--no-browser", action="store_true")
    sub.add_parser("status")
    sub.add_parser("disconnect")
    exchange = sub.add_parser("exchange")
    exchange.add_argument("--request", required=True)
    exchange.add_argument("--resolution", choices=["local", "remote"])
    exchange.add_argument("--revision")
    ack = sub.add_parser("ack")
    ack.add_argument("--request", required=True)
    usage = sub.add_parser("upload-usage")
    usage.add_argument("--summary", required=True)
    args = parser.parse_args()
    os.umask(0o077)
    directory = private_directory(args.state_dir)
    with (directory / "sync.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.command == "authorize":
            result = authorize(directory, args.client, args.port, args.no_browser)
        elif args.command == "disconnect":
            with contextlib.suppress(FileNotFoundError):
                (directory / "credentials.json").unlink()
            result = {"status": "disconnected"}
        elif args.command == "status":
            if not (directory / "credentials.json").exists():
                result = {"status": "disconnected"}
            else:
                google = Google(directory)
                result = {"status": "connected", "account": google.account}
        else:
            google = Google(directory)
            sync = Sync(google, directory)
            if args.command == "exchange":
                result = sync.exchange(read_json(args.request), args.resolution, args.revision)
                result["usage"] = sync.usage()
                result["folderURL"] = google.folder_url()
            elif args.command == "ack":
                value = read_json(args.request)
                sync.acknowledge(value["clock"], value["digest"])
                result = {"status": "acknowledged"}
            else:
                sync.upload_usage(read_json(args.summary, MAX_SUMMARY))
                result = {"status": "uploaded"}
        print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (SyncError, OSError, ValueError, KeyError, TypeError) as error:
        # Never include token endpoints' response bodies or authorization codes in diagnostics.
        message = str(error) if isinstance(error, SyncError) else "Cloud sync failed; check configuration and network"
        print(json.dumps({"error": message}), file=sys.stderr)
        sys.exit(1)
