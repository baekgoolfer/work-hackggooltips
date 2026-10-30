"""Helpers of tests/test_gcal.py (stdlib only): a FAKE macOS `security` that understands what gcal.py uses (find/delete, the direct and the
``security -i`` form of add-generic-password with ``-w`` or ``-X``), the document-derived fixtures of fixtures/gcal/, canary secrets, and
``GcalCase``, a temp world (config, private OAuth client file, fake Keychain, fake clock) on top of ``LaneCase``.

Nothing here touches the real Keychain, the network or a real Google account. The only secrets are the CANARY values below: they must never
show up in any file, log line, argv or output of a command (``leaks`` scans for them).
"""
from __future__ import annotations

import json
import os
import stat
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from unittest import mock
from urllib.parse import parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # pipeline/ on sys.path when run via discover

from asr_support import FakeTransport, json_response  # noqa: E402
from test_lanes import LaneCase  # noqa: E402

from mcap import apikey, gcal  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "gcal"
NOW = datetime(2026, 10, 7, 5, 0, 0, tzinfo=timezone.utc).timestamp()      # 14:00 in +09:00
ACCOUNT = "owner@example.test"
REFRESH = "1//0gCANARY-refresh-rrrrrrrrrrrr"
ACCESS = "ya29.CANARY-access-aaaaaaaaaaaaaaaa"
NEW_ACCESS = "ya29.CANARY-newaccess-nnnnnnnnnnnn"
NEW_REFRESH = "1//0gCANARY-newrefresh-nnnnnnnnnn"
CLIENT_SECRET = "GOCSPX-CANARY-secret-ssssssssssss"
CODE = "4/0CANARY-code-cccccccccccc"
NEEDLES = ("CANARY", "ya29.", "GOCSPX-")

_FAKE_SECURITY = r'''
import json, os, shlex, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(HERE, "keychain.json")
def mode():
    try: return open(os.path.join(HERE, "mode")).read().strip()
    except OSError: return "ok"
def load():
    try: return json.load(open(STORE))
    except (OSError, ValueError): return {}
def save(items): json.dump(items, open(STORE, "w"))
def opt(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None
def log(argv, stdin):
    with open(os.path.join(HERE, "calls.jsonl"), "a") as fh:
        fh.write(json.dumps({"argv": argv, "stdin": stdin}) + "\n")
def add(argv):
    if mode() == "ignore-add":
        return 0
    if "-X" in argv:
        try: password = bytes.fromhex(opt(argv, "-X")).decode("utf-8")
        except ValueError: return 1
    else:
        password = opt(argv, "-w")
    items = load(); items[opt(argv, "-s") + "\t" + opt(argv, "-a")] = password; save(items)
    return 0
argv = sys.argv[1:]
if argv[:1] == ["-i"]:
    data = sys.stdin.read()
    log(argv, data)
    if mode() == "fail-add":
        sys.exit(1)
    for line in data.splitlines():
        words = shlex.split(line)
        if words[:1] == ["add-generic-password"]:
            add(words)
    sys.exit(0)
log(argv, None)
cmd = argv[0] if argv else ""
key = (opt(argv, "-s") or "") + "\t" + (opt(argv, "-a") or "")
if cmd == "find-generic-password":
    if mode() == "timeout": time.sleep(120)
    if mode() == "deny":
        sys.stderr.write("security: User interaction is not allowed.\n"); sys.exit(36)
    items = load()
    if key in items:
        if "-w" in argv:
            out = items[key]
            sys.stdout.write((out.encode("utf-8").hex() if mode() == "hexout" else out) + "\n")
        else:
            sys.stdout.write('keychain: "login.keychain"\nclass: "genp"\n')
        sys.exit(0)
    sys.stderr.write("security: The specified item could not be found in the keychain.\n"); sys.exit(44)
if cmd == "add-generic-password":
    sys.exit(add(argv))
if cmd == "delete-generic-password":
    if mode() == "deny": sys.exit(36)
    items = load()
    if key in items:
        del items[key]; save(items); sys.exit(0)
    sys.exit(44)
sys.exit(2)
'''


class FakeKeychain:
    """A throwaway `security` executable for $MCAP_SECURITY_BIN. ``items`` is the fake Keychain; ``calls()`` the argv (and the stdin of ``-i``) of
    every call. ``set_mode``: ok | timeout | deny | hexout (find prints the data as hex) | ignore-add (``add`` exits 0 and keeps nothing) | fail-add (``security -i`` exits 1)."""

    def __init__(self, directory: Path):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)
        script = self.dir / "fake_security.py"
        script.write_text(_FAKE_SECURITY, encoding="utf-8")
        self.path = self.dir / "security"
        self.path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        self.path.chmod(self.path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def put(self, text: str, service: str = gcal.TOKEN_SERVICE, account: Optional[str] = None) -> None:
        items = self.items()
        items[service + "\t" + (account or apikey.keychain_account())] = text
        (self.dir / "keychain.json").write_text(json.dumps(items), encoding="utf-8")

    def items(self) -> dict:
        path = self.dir / "keychain.json"
        return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}

    def stored(self) -> Optional[gcal.Token]:
        text = self.items().get(gcal.TOKEN_SERVICE + "\t" + apikey.keychain_account())
        return gcal.Token.load(text) if text else None

    def clear(self) -> None:
        (self.dir / "keychain.json").unlink(missing_ok=True)

    def set_mode(self, mode: str) -> None:
        (self.dir / "mode").write_text(mode, encoding="utf-8")

    def calls(self) -> list:
        path = self.dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()] if path.exists() else []

    def argvs(self, command: Optional[str] = None) -> list:
        return [c["argv"] for c in self.calls() if command is None or (c["argv"] and c["argv"][0] == command)]


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


def token_doc(**override) -> dict:
    return {**fixture("token_response.json"), "access_token": NEW_ACCESS, "refresh_token": NEW_REFRESH, **override}


def refresh_doc(**override) -> dict:
    """Google's answer to a refresh: a new access token and no refresh token."""
    doc = token_doc(**override)
    doc.pop("refresh_token", None)
    return doc


class GcalCase(LaneCase):
    """``self.cfg`` (no policy, support dir under the temp root), a private client file, a fake Keychain, a signed-in token that is valid for 30
    more minutes, a fake clock (``self.now``) and ``self.google`` (an in-process transport that answers like Google, ``self.google.calls``)."""

    def setUp(self) -> None:
        super().setUp()
        self.addCleanup(apikey._known.clear)
        self.keychain = FakeKeychain(Path(self._tmp_keychain.name) / "gcal-keychain")
        patcher = mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.keychain.path)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.now = NOW
        self.write_client()
        self.sign_in()
        self.events_doc = fixture("events_list.json")
        self.google = FakeTransport(handler=self.answer)

    # ---- the world
    def write_client(self, doc: Optional[dict] = None, mode: int = 0o600) -> Path:
        path = gcal.client_path(self.cfg)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        path.write_text(json.dumps(doc if doc is not None else fixture("client_installed.json")), encoding="utf-8")
        path.chmod(mode)
        return path

    def sign_in(self, access: str = ACCESS, expires_in: int = 1800, refresh: str = REFRESH) -> None:
        self.keychain.put(gcal.Token(refresh, access, int(NOW) + expires_in, ACCOUNT).dump())

    def answer(self, call):
        """What Google answers (the two hosts of the guard)."""
        if call.rule.host == gcal.TOKEN_HOST and call.path == "/token":
            grant = parse_qs(call.body.decode("ascii")).get("grant_type", [""])[0]
            return json_response(200, refresh_doc() if grant == "refresh_token" else token_doc())
        if call.rule.host == gcal.API_HOST and call.path == "/calendar/v3/calendars/primary/events":
            return json_response(200, self.events_doc)
        if call.rule.host == gcal.API_HOST and call.path == "/calendar/v3/calendars/primary":
            return json_response(200, fixture("calendar_primary.json"))
        return json_response(404, {"error": {"code": 404}})

    def upcoming(self, back: int = 15, ahead: int = 30, **kw) -> dict:
        kw.setdefault("transport", self.google)
        kw.setdefault("clock", lambda: self.now)
        return gcal.upcoming(self.cfg, back, ahead, **kw)

    def failure_of(self, **kw) -> gcal.GcalError:
        with self.assertRaises(gcal.GcalError) as cm:
            self.upcoming(**kw)
        return cm.exception

    def leaks(self, *extra_text: str) -> list:
        """Files under the temp root (the fake Keychain lives outside it; the owner's own client file is skipped) and every string given that
        contain ANY canary fragment."""
        hits = []
        client = gcal.client_path(self.cfg)
        for path in sorted(self.root.rglob("*")):
            if path.is_file() and path != client:
                data = path.read_bytes()
                if any(n.encode() in data for n in NEEDLES):
                    hits.append(str(path))
        hits += [f"<text #{i}>" for i, text in enumerate(extra_text) if any(n in text for n in NEEDLES)]
        return hits
