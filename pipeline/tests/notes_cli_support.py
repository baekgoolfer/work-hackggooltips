"""Shared helpers for the notes/CLI tests (stdlib only): a FAKE `claude` executable, a FAKE macOS `security` tool (the Keychain),
temp config, fake sessions and fake transcription collaborators. Nothing in here touches the real SUPPORT_DIR, ARCHIVE_DIR,
Google Drive, the real Keychain or the real claude. No real API key exists in this environment: the only key is the CANARY below,
which must never appear in any file, log, argv or output of a run (tests/test_apikey.py scans for it)."""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Optional
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))   # pipeline/ on sys.path when run via discover

from mcap.config import Config  # noqa: E402

START = "2026-10-07T14:00:12+09:00"
END = "2026-10-07T15:03:40+09:00"

# A fake key with the real shape. It is served by FakeSecurity and must never show up anywhere else.
CANARY = "sk-ant-api03-CANARY-" + "0" * 40 + "-ZZ"
# A key without the sk-ant- shape (the exact-value masking of apikey.redact must catch it as well).
ODD_CANARY = "canary_ODD_key_value_9f8e7d6c5b4a"

# ---------------------------------------------------------------------------------- fake claude
_FAKE_SCRIPT = r'''
import json, os, signal, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
SCEN = json.load(open(os.path.join(HERE, "scenario.json")))
argv = sys.argv[1:]

def log_call(extra):
    n = 0
    try: n = int(open(os.path.join(HERE, "counter")).read())
    except Exception: pass
    n += 1
    open(os.path.join(HERE, "counter"), "w").write(str(n))
    env = dict(os.environ)
    if "ANTHROPIC_API_KEY" in env:      # the recorded env must never hold the key itself: its sha256 proves WHICH key arrived
        import hashlib
        env["ANTHROPIC_API_KEY"] = "sha256:" + hashlib.sha256(env["ANTHROPIC_API_KEY"].encode()).hexdigest()
    rec = {"n": n, "argv": argv, "env": env, "cwd": os.getcwd()}
    rec.update(extra)
    fd = os.open(os.path.join(HERE, "calls.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try: os.write(fd, (json.dumps(rec) + "\n").encode("utf-8"))
    finally: os.close(fd)
    return n

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()

def on_term(signum, frame):
    open(os.path.join(HERE, "terminated"), "w").write("1")
    sys.exit(143)
signal.signal(signal.SIGTERM, on_term)

if argv[:2] == ["auth", "status"]:
    log_call({"kind": "auth"})
    a = SCEN.get("auth", {})
    sys.stdout.write(json.dumps(a.get("json", {"loggedIn": True, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "pro"})))
    sys.exit(a.get("exit", 0))
if argv[:1] == ["--version"]:
    print(SCEN.get("version", "2.1.278 (Claude Code)")); sys.exit(0)

def init_event(api_key_source=None, model="claude-opus-5"):
    """apiKeySource like the real CLI: "ANTHROPIC_API_KEY" when the key is in the environment, else "none" (explicit value wins)."""
    src = api_key_source or ("ANTHROPIC_API_KEY" if os.environ.get("ANTHROPIC_API_KEY") else "none")
    return {"type": "system", "subtype": "init", "session_id": "s1", "model": model, "tools": [], "mcp_servers": [],
            "apiKeySource": src, "claude_code_version": SCEN.get("claude_version", "2.1.278")}

def rl_event(status="allowed", overage=False, resets=None, rtype="five_hour"):
    return {"type": "rate_limit_event", "rate_limit_info": {"status": status, "resetsAt": resets or SCEN.get("resets_at", 1791372000),
            "rateLimitType": rtype, "isUsingOverage": overage}, "session_id": "s1"}

COST = [SCEN.get("cost", 0.05)]      # total_cost_usd of the next successful result (a plan can override it: "cost")

def result(text, model="claude-opus-5", is_error=False, status=None, stop="end_turn", terminal="completed", provider="firstParty"):
    res = {"type": "result", "subtype": "success", "is_error": is_error, "api_error_status": status, "result": text,
           "stop_reason": stop, "terminal_reason": terminal, "session_id": "s1",
           "modelUsage": {model: {"inputTokens": 10, "outputTokens": 20, "provider": provider}} if not is_error else {}}
    if not SCEN.get("no_cost"):
        res["total_cost_usd"] = 0.0 if is_error else COST[0]
    return res

def assistant_text(text, model="claude-opus-5"):
    return {"type": "assistant", "message": {"role": "assistant", "model": model, "stop_reason": None,
            "content": [{"type": "text", "text": text}]}}

def count_kind(kind):
    cnt = 0
    try:
        for line in open(os.path.join(HERE, "calls.jsonl")):
            if json.loads(line).get("kind") == kind: cnt += 1
    except Exception: pass
    return cnt

def detect_kind(stdin):
    import re
    if re.search(r"^<draft_note>$", stdin, re.M): return "verify"
    if re.search(r"^<segments>$", stdin, re.M): return "cleanup"
    return "note"

def plan_for(kind):
    n = count_kind(kind) - 1                      # index of THIS call among the calls of its kind (it is already logged)
    if kind == "note":
        runs = SCEN.get("runs", [{"mode": "success"}])
        return runs[min(max(n - SCEN.get("note_offset", 0), 0), len(runs) - 1)]
    spec = SCEN.get(kind) or {}
    runs = spec.get("runs")
    if runs:
        return runs[min(max(n - SCEN.get("offsets", {}).get(kind, 0), 0), len(runs) - 1)]
    return spec

def respond(plan, text):
    mode = plan.get("mode", "success")
    model = plan.get("model", "claude-opus-5")
    COST[0] = plan.get("cost", SCEN.get("cost", 0.05))
    leak = os.environ.get("ANTHROPIC_API_KEY", "") if (plan.get("leak_key") or SCEN.get("leak_key")) else ""   # an error text that echoes the key
    if plan.get("grandchild"):                         # a helper that inherits our pipes and outlives us
        pid = os.fork()
        if pid == 0:
            time.sleep(60); os._exit(0)
        open(os.path.join(HERE, "grandchild.pid"), "w").write(str(pid))
    if mode == "violation":
        emit(init_event("ANTHROPIC_API_KEY", model)); emit(result(text, model)); return
    if mode == "fallback_login":                       # api mode, but the CLI fell back to the login: apiKeySource says "none"
        emit(init_event("none", model)); emit(assistant_text(text, model)); emit(result(text, model)); return
    emit(init_event(None, model))
    if mode == "crash":
        sys.stderr.write("boom: network unreachable " + leak + "\n"); sys.exit(1)
    if mode == "timeout":
        time.sleep(120); return
    if mode == "overage_early":
        emit(rl_event(overage=True)); time.sleep(120); return
    if mode == "success" or mode == "overage_late" or mode == "violation_provider":
        emit(assistant_text(text, model))
        emit(rl_event(overage=(mode == "overage_late" or plan.get("overage", False))))
        emit(result(text, model, provider=("bedrock" if mode == "violation_provider" else "firstParty")))
    elif mode == "usage_limit":
        scope = plan.get("scope", "session")
        emit(rl_event("rejected", False, plan.get("resets")))
        emit({"type": "assistant", "error": "rate_limit", "message": {"role": "assistant", "content": [{"type": "text", "text": "limit"}]}})
        emit(result("You've hit your %s limit · resets 6pm (Asia/Seoul)" % scope, model, True, 429, "stop_sequence", "api_error"))
    elif mode == "rate_limited":
        emit({"type": "assistant", "error": "rate_limit", "message": {"role": "assistant", "content": []}})
        emit(result("Number of request tokens has exceeded your per-minute rate limit", model, True, 429, "stop_sequence", "api_error"))
    elif mode == "overloaded":
        emit({"type": "assistant", "error": "server_error", "message": {"role": "assistant", "content": []}})
        emit(result("Overloaded", model, True, 529, "stop_sequence", "api_error"))
    elif mode == "auth":
        emit({"type": "assistant", "error": "authentication_failed", "message": {"role": "assistant", "content": []}})
        emit(result("Not logged in · Please run /login", model, True, 401, "stop_sequence", "api_error"))
    elif mode == "billing":
        emit({"type": "assistant", "error": "billing_error", "message": {"role": "assistant", "content": []}})
        emit(result("Credit balance is too low", model, True, 400, "stop_sequence", "api_error"))
    elif mode == "api_401":                            # api mode: the key was rejected
        emit({"type": "assistant", "error": "authentication_failed", "message": {"role": "assistant", "content": []}})
        emit(result("Invalid API key · Fix external API key" + (" (" + leak + ")" if leak else ""), model, True, 401, "stop_sequence", "api_error"))
    elif mode == "api_credit":                         # api mode: the Console balance is empty
        emit({"type": "assistant", "error": "billing_error", "message": {"role": "assistant", "content": []}})
        emit(result("Credit balance is too low" + (" " + leak if leak else ""), model, True, 400, "stop_sequence", "api_error"))
    elif mode == "api_spend_limit":                    # api mode: the Console monthly spend limit of the workspace is reached
        emit({"type": "assistant", "error": "invalid_request", "message": {"role": "assistant", "content": []}})
        emit(result("You have reached your specified workspace API usage limits. You will regain access on 2026-11-01 at 00:00 UTC.",
                    model, True, 400, "stop_sequence", "api_error"))
    elif mode == "api_429":                            # api mode: the API's own rate limit (no rate_limit_event, no subscription window)
        emit({"type": "assistant", "error": "rate_limit", "message": {"role": "assistant", "content": []}})
        emit(result("API Error: 429 rate_limit_error: Number of request tokens has exceeded your per-minute rate limit", model, True, 429,
                    "stop_sequence", "api_error"))
    elif mode == "truncated":
        emit(assistant_text(text, model)); emit(rl_event()); emit(result(text, model, stop="max_tokens", terminal="max_tokens"))
    elif mode == "empty":
        emit(rl_event()); emit(result("", model))
    elif mode == "invalid":
        emit(assistant_text("Sure! Here is a short summary.", model)); emit(rl_event()); emit(result("Sure! Here is a short summary.", model))
    elif mode == "preamble":
        wrapped = "Here is the result you asked for:\n\n```markdown\n" + text + "\n```\n"
        emit(assistant_text(wrapped, model)); emit(rl_event()); emit(result(wrapped, model))

def block(stdin, tag):
    import re
    starts = [m.end() for m in re.finditer(r"^<%s>$" % tag, stdin, re.M)]
    if not starts: return ""
    rest = stdin[starts[-1]:]
    m = re.search(r"^</%s>$" % tag, rest, re.M)
    return (rest[:m.start()] if m else rest).strip("\n")

def cleanup_text(plan, stdin):
    if "reply" in plan: return plan["reply"]
    needle = plan.get("fail_if_contains")
    rows = [json.loads(l) for l in block(stdin, "segments").splitlines() if l.strip().startswith("{")]
    edits = []
    for row in rows:
        if row.get("role") != "target": continue
        text = row["text"]; new = text
        for old, rep in (plan.get("replacements") or {}).items():
            new = new.replace(old, rep)
        for sub, whole in (plan.get("rewrite") or {}).items():
            if sub in text: new = whole
        if new != text: edits.append({"id": row["id"], "text": new})
    edits += plan.get("extra_edits") or []
    return json.dumps(edits, ensure_ascii=False)

def verify_text(plan, stdin):
    if "reply" in plan: return plan["reply"]
    if "note" in plan: return plan["note"]
    lines = block(stdin, "draft_note").split("\n")
    out = []
    for line in lines:
        if any(sub in line for sub in plan.get("remove", [])): continue
        for old, rep in (plan.get("replace") or {}).items(): line = line.replace(old, rep)
        if any(sub in line for sub in plan.get("mark", [])): line = line + " (근거 불명확 / not supported by transcript)"
        out.append(line)
    out += plan.get("append", [])
    return "\n".join(out)

def run_note():
    stdin = sys.stdin.buffer.read().decode("utf-8", "replace")
    time.sleep(float(SCEN.get("delay", 0.0)))
    kind = detect_kind(stdin)
    log_call({"kind": kind, "stdin": stdin})
    plan = plan_for(kind)
    if kind == "cleanup":
        if plan.get("fail_if_contains") and plan["fail_if_contains"] in block(stdin, "segments"):
            respond({"mode": "overloaded"}, ""); return
        respond(plan, cleanup_text(plan, stdin))
    elif kind == "verify":
        respond(plan, verify_text(plan, stdin))
    else:
        respond(plan, plan.get("note", SCEN.get("note", "")))

def run_calendar():
    cal = SCEN.get("calendar", {})
    mode = cal.get("mode", "ok")
    log_call({"kind": "calendar"})
    turn = 0
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        turn += 1
        with open(os.path.join(HERE, "calendar_asks.jsonl"), "a") as fh:      # what the pipeline asked the model, turn by turn
            fh.write(line + "\n")
        emit(init_event(None, "claude-sonnet-5"))
        if mode == "overage":
            emit(rl_event(overage=True))
        if turn == 1:
            if mode == "error":
                emit(result("API Error", "claude-sonnet-5", True, 500)); continue
            emit(assistant_text("OK", "claude-sonnet-5")); emit(result("OK", "claude-sonnet-5"))
            if mode == "hang": time.sleep(120)
        else:
            if mode != "no_tool":
                events = cal.get("events", [])
                payload = {"accessRole": "owner", "timeZone": "Asia/Seoul"}
                if events: payload["events"] = events
                emit({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "mcp__claude_ai_Google_Calendar__list_events", "input": {}}]}})
                emit({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": json.dumps(payload)}]}})
            emit(assistant_text("DONE", "claude-sonnet-5")); emit(result("DONE", "claude-sonnet-5"))

if "--input-format" in argv:
    run_calendar()
else:
    run_note()
'''


# ---------------------------------------------------------------------------------- fake security (the Keychain)
_FAKE_SECURITY = r'''
import json, os, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[1:]
fd = os.open(os.path.join(HERE, "calls.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.write(fd, (json.dumps({"argv": argv, "stdin_tty": sys.stdin.isatty()}) + "\n").encode()); os.close(fd)
mode = "ok"
try: mode = open(os.path.join(HERE, "mode")).read().strip() or "ok"
except OSError: pass
item = None
try: item = json.load(open(os.path.join(HERE, "item.json")))
except (OSError, ValueError): pass
extra = []                      # items.json: any number of further (service, account, password) items (store_item)
try: extra = json.load(open(os.path.join(HERE, "items.json")))
except (OSError, ValueError): pass
def opt(flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None
def served():
    for it in ([item] if item else []) + extra:
        if opt("-s") == it["service"] and opt("-a") == it["account"]:
            return it
    return None
cmd = argv[0] if argv else ""
if cmd == "find-generic-password":
    if mode == "timeout":
        time.sleep(120)
    if mode == "deny":
        sys.stderr.write("security: SecKeychainSearchCopyNext: User interaction is not allowed.\n"); sys.exit(36)
    found = served()
    if found:
        if "-w" in argv:
            sys.stdout.write(found["password"] + "\n")
        else:
            sys.stdout.write('keychain: "login.keychain"\nclass: "genp"\n')
        sys.exit(0)
    sys.stderr.write("security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n")
    sys.exit(44)
if cmd == "add-generic-password":
    sys.exit(int(open(os.path.join(HERE, "add_exit")).read()) if os.path.exists(os.path.join(HERE, "add_exit")) else 0)
if cmd == "delete-generic-password":
    if item and opt("-s") == item["service"] and opt("-a") == item["account"]:
        os.unlink(os.path.join(HERE, "item.json")); sys.exit(0)
    kept = [it for it in extra if not (opt("-s") == it["service"] and opt("-a") == it["account"])]
    if len(kept) != len(extra):
        json.dump(kept, open(os.path.join(HERE, "items.json"), "w")); sys.exit(0)
    sys.exit(44)
sys.exit(2)
'''
SECURITY_DIRNAME = "security-shim"           # the shim's directory IS the fake Keychain: scans for the canary skip it


class FakeSecurity:
    """A throwaway `security` executable for $MCAP_SECURITY_BIN: serves the stored password for find-generic-password (-w) and records
    the argv of every call. The real Keychain is never touched. `store()` puts a password (default: the CANARY) in the fake
    Keychain under the service / account the program will ask for."""

    def __init__(self, directory: Path):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)
        script = self.dir / "fake_security.py"
        script.write_text(_FAKE_SECURITY, encoding="utf-8")
        self.path = self.dir / "security"
        self.path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        self.path.chmod(self.path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def store(self, password: str = CANARY, service: Optional[str] = None, account: Optional[str] = None) -> None:
        from mcap import apikey
        item = {"service": service or apikey.DEFAULT_SERVICE, "account": account or apikey.keychain_account(), "password": password}
        (self.dir / "item.json").write_text(json.dumps(item), encoding="utf-8")

    def store_item(self, password: str, service: str, account: str) -> None:
        """Put one more (service, account) item in the fake Keychain (several can exist at once: the Anthropic key, the relay token,
        the Azure key ...). Same (service, account) again replaces the password. `store()` keeps serving its single item as before."""
        path = self.dir / "items.json"
        items = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
        items = [it for it in items if not (it["service"] == service and it["account"] == account)]
        items.append({"service": service, "account": account, "password": password})
        path.write_text(json.dumps(items), encoding="utf-8")

    def remove(self) -> None:
        (self.dir / "item.json").unlink(missing_ok=True)
        (self.dir / "items.json").unlink(missing_ok=True)

    def set_mode(self, mode: str) -> None:
        """ok | timeout (never answers) | deny (exit 36: interaction not allowed)."""
        (self.dir / "mode").write_text(mode, encoding="utf-8")

    def set_add_exit(self, code: int) -> None:
        (self.dir / "add_exit").write_text(str(code), encoding="utf-8")

    def calls(self) -> list[dict]:
        path = self.dir / "calls.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

    def argvs(self, command: Optional[str] = None) -> list[list[str]]:
        return [c["argv"] for c in self.calls() if command is None or (c["argv"] and c["argv"][0] == command)]

    def reads(self, service: Optional[str] = None) -> int:
        """How often the key itself was asked for (find-generic-password ... -w); with `service` only reads of that Keychain service."""
        def asked(argv: list) -> bool:
            if "-w" not in argv:
                return False
            if service is None:
                return True
            return "-s" in argv and argv.index("-s") + 1 < len(argv) and argv[argv.index("-s") + 1] == service
        return sum(1 for argv in self.argvs("find-generic-password") if asked(argv))


def canary_hits(root: Path, *, skip=(SECURITY_DIRNAME,), extra: tuple = ()) -> list[str]:
    """Every file under `root` (except the fake Keychain) and every string in `extra` that contains ANY fragment of a canary key.
    The markers are deliberately short: a half-masked or truncated key is a leak too."""
    needles = (b"CANARY", b"canary_ODD", CANARY.encode()[:24], ODD_CANARY.encode()[:12])
    hits = []
    for path in sorted(Path(root).rglob("*")):
        if not path.is_file() or any(part in skip for part in path.relative_to(root).parts):
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if any(n in data for n in needles):
            hits.append(str(path))
    for i, text in enumerate(extra):
        raw = text.encode("utf-8", "replace") if isinstance(text, str) else bytes(text)
        if any(n in raw for n in needles):
            hits.append(f"<extra #{i}>")
    return hits


class FakeClaude:
    """A throwaway `claude` executable. `scenario` is re-read on every invocation, so tests can change it at any time."""

    def __init__(self, directory: Path):
        self.dir = Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)
        script = self.dir / "fake_claude.py"
        script.write_text(_FAKE_SCRIPT, encoding="utf-8")
        self.path = self.dir / "claude"
        self.path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n', encoding="utf-8")
        self.path.chmod(self.path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.scenario: dict = {}
        self.set()

    def set(self, runs: Optional[list] = None, **kwargs) -> None:
        """Install a scenario; `runs` are consumed one per note invocation from now on."""
        self.scenario = {"runs": runs or [{"mode": "success", "note": sample_note()}],
                         "note_offset": len(self.calls("note")),
                         "offsets": {"cleanup": len(self.calls("cleanup")), "verify": len(self.calls("verify"))}, **kwargs}
        (self.dir / "scenario.json").write_text(json.dumps(self.scenario), encoding="utf-8")

    def calls(self, kind: Optional[str] = None) -> list[dict]:
        path = self.dir / "calls.jsonl"
        if not path.exists():
            return []
        rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
        return [r for r in rows if kind is None or r.get("kind") == kind]

    def terminated(self) -> bool:
        return (self.dir / "terminated").exists()

    def calendar_asks(self) -> list[str]:
        """The user messages the calendar lookup sent to the fake (turn 1: the no-op, turn 2: the list_events request)."""
        path = self.dir / "calendar_asks.jsonl"
        if not path.exists():
            return []
        return [json.loads(line)["message"]["content"] for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def sample_note(title: str = "Weekly Sync", extra: str = "") -> str:
    return textwrap.dedent(f"""\
        # {title}

        Date: 1999-01-01
        Time: model wrote the wrong time
        Platform: Model Platform
        Participants: Me, Alice (named in conversation)
        ※ Remote speakers are not separated.

        ## Executive Summary
        - Pilot price discussed: USD 7,500 for three sites and 90 days [00:02:10].
        - Volume discount tier not decided.

        ## Key Discussion
        **Pricing**
        - the user stated the pilot price. {extra}

        ## Decisions
        No explicit decisions were stated.

        ## Action Items
        | Owner | Action | Due |
        |---|---|---|
        | Me | Send the BAA draft to Alice | Not stated |

        ## Open Questions
        - Exact volume discount tier.

        ## Follow-up
        - Next sync, date as stated: Thursday the nineteenth.

        ## Important Details
        - Pilot: USD 7,500; license USD 2,500 per site per year.
        """)


# ---------------------------------------------------------------------------------- config / sessions
CHILD_ENV_NOISE = ("LC_", "__CF", "PWD", "SHLVL", "_", "OLDPWD")     # added by /bin/sh and macOS, not by us


def real_env_keys(env: dict) -> set:
    return {k for k in env if not k.startswith(CHILD_ENV_NOISE) and k not in CHILD_ENV_NOISE}


def make_cfg(root: Path, fake: Optional[FakeClaude] = None, **overrides) -> Config:
    """Config whose every path lives under `root` (nothing real is touched)."""
    root = Path(root)
    support = root / "Support Dir"          # spaces on purpose
    cfg = Config(
        support_dir=support,
        archive_dir=root / "Drive" / "My Drive" / "Meetings",
        project_dir=Path(__file__).resolve().parents[2],
        python_bin=Path(sys.executable),
        claude_bin=fake.path if fake else root / "no-such-claude",
        calendar_lookup="0",
        transcript_cleanup=False,       # the LLM quality passes are opt-in inside the tests (they have their own test files)
        note_verify=False,
        note_stop_on_overage=False,     # off in the fixtures (the built-in default is on); guard tests switch it on explicitly
        claude_auth="subscription",     # the fixtures never touch a Keychain (the built-in default is api); api tests say so explicitly
        policy_path=root / "no-policy" / "policy.json",     # never exists: a test must not see (or depend on) the real system policy
    )
    (root / "Drive" / "My Drive").mkdir(parents=True, exist_ok=True)
    support.mkdir(parents=True, exist_ok=True)
    for key, value in overrides.items():
        setattr(cfg, key, value)
    return cfg


def fake_m4a(path: Path, size: int = 2048) -> None:
    path.write_bytes(b"\x00\x00\x00\x20ftypM4A " + b"\x00" * (size - 12))


def make_session(cfg: Config, session_id: str = "2026-10-07_1400_meet", *, start: str = START, end: Optional[str] = END,
                 platform: str = "meet", label: str = "Google Meet", title_hint: Optional[str] = "Meet – abc-defg-hij",
                 meeting_url: Optional[str] = "https://meet.google.com/abc-defg-hij", wavs: bool = True,
                 tracks=("mic", "remote")) -> Path:
    d = Path(cfg.sessions_dir) / session_id
    d.mkdir(parents=True, exist_ok=True)
    session = {"schema": 1, "session_id": session_id, "platform": platform, "platform_label": label,
               "title_hint": title_hint, "meeting_url": meeting_url, "app_bundle_id": "com.google.Chrome",
               "start_time": start, "end_time": end, "end_reason": "meeting-ended",
               "tracks": {t: {"file": f"{t}.wav", "sample_rate": 48000, "channels": 1, "start_offset_sec": 0.03,
                              "source": "mic", "device": "x"} for t in tracks},
               "app_version": "0.1.0"}
    (d / "session.json").write_text(json.dumps(session), encoding="utf-8")
    if wavs:
        for t in tracks:
            (d / f"{t}.wav").write_bytes(b"RIFF" + b"\x00" * 4096)
    return d


class FakeASR:
    """Replacement for audioprep + asr + transcript. Counts calls; can fail on demand."""

    def __init__(self, speech_seconds: float = 120.0, fail_audio: Optional[str] = None, fail_asr: Optional[str] = None,
                 model: str = "mlx-community/whisper-large-v3-mlx", segments: Optional[list] = None):
        self.speech_seconds = speech_seconds
        self.fail_audio, self.fail_asr, self.model = fail_audio, fail_asr, model
        self.segments = segments                      # explicit segment dicts (cleanup tests) instead of the two canned ones
        self.audio_calls: list[dict] = []
        self.asr_calls = 0

    def prepare_audio(self, session_dir, session, force=False):
        self.audio_calls.append({"force": force})
        if self.fail_audio:
            raise RuntimeError(self.fail_audio)
        files = {}
        for name in ("audio", "mic", "remote"):
            fake_m4a(Path(session_dir) / f"{name}.m4a")
            files[name] = Path(session_dir) / f"{name}.m4a"
        return SimpleNamespace(tracks={}, sample_rate=16000, duration_sec=3808.0, archive_files=files)

    def transcribe_tracks(self, prepared, cfg, vocab, progress=lambda m: None):
        self.asr_calls += 1
        progress("remote 1/2")
        if self.fail_asr:
            raise RuntimeError(self.fail_asr)
        half = self.speech_seconds / 2
        if self.segments is not None:
            return {"schema": 1, "asr_model": self.model, "languages": {"mic": "ko", "remote": "en"}, "dropped": 0,
                    "segments": [dict(s) for s in self.segments]}
        return {"schema": 1, "asr_model": self.model, "languages": {"mic": "ko", "remote": "en"}, "dropped": 0,
                "segments": [
                    {"start": 13.2, "end": 13.2 + half, "speaker": "Me", "track": "mic", "lang": "ko",
                     "text": "안녕하세요 pricing is USD 7,500.", "avg_logprob": -0.2, "no_speech_prob": 0.01},
                    {"start": 40.0, "end": 40.0 + half, "speaker": "Remote", "track": "remote", "lang": "en",
                     "text": "Understood, one hundred twenty thousand dollars.", "avg_logprob": -0.3, "no_speech_prob": 0.02}]}

    def render_markdown(self, transcript, meta):
        lines = ["# Transcript", "", f"Meeting: {meta['title']}", f"Date: {meta['date']}", f"Platform: {meta['platform_label']}",
                 f"ASR: {meta['asr_model']}", ""]
        for seg in transcript["segments"]:
            lines += [f"[{int(seg['start'] // 3600):02d}:{int(seg['start'] % 3600 // 60):02d}:{int(seg['start'] % 60):02d}] {seg['speaker']}",
                      seg["text"], ""]
        return "\n".join(lines)

    def deps(self, **extra):
        from mcap.pipeline import Deps
        return Deps(prepare_audio=self.prepare_audio, transcribe_tracks=self.transcribe_tracks,
                    render_markdown=self.render_markdown, **extra)


def ready_ok(cfg, allow_overage=False):
    from mcap import note
    return note.Readiness(True, info={"authMethod": "claude.ai", "apiProvider": "firstParty"})


class StubNote:
    """generate_note replacement: records calls, returns a canned NoteResult, can run a hook first."""

    def __init__(self, ok: bool = True, text: Optional[str] = None, kind: str = "usage_limit", error: str = "Claude usage limit reached",
                 retryable: bool = True, resets_at: Optional[int] = None, warning: str = "", hook=None, raises: Optional[Exception] = None):
        self.ok, self.text, self.kind, self.error = ok, text if text is not None else sample_note(), kind, error
        self.retryable, self.resets_at, self.warning, self.hook, self.raises = retryable, resets_at, warning, hook, raises
        self.calls: list[dict] = []

    def __call__(self, transcript_md, meta, cfg, vocab, allow_overage=False, ready=None):
        from mcap import note
        self.calls.append({"transcript_md": transcript_md, "meta": meta, "allow_overage": allow_overage})
        if self.hook:
            self.hook()
        if self.raises:
            raise self.raises
        if self.ok:
            return note.NoteResult(True, text=self.text, model="claude-opus-5", claude_version="2.1.278", warning=self.warning)
        return note.NoteResult(False, error_kind=self.kind, error=self.error, retryable=self.retryable,
                               resets_at=self.resets_at, warning=self.warning)


def age_files(directory: Path, seconds: float = 3600.0) -> None:
    """Make every file of a session dir look old (a recording that stopped long ago / crashed)."""
    import time
    past = time.time() - seconds
    for entry in Path(directory).iterdir():
        os.utime(entry, (past, past))


class StubCleanup:
    """cleanup_transcript replacement: records calls, returns a canned CleanupResult (or raises)."""

    def __init__(self, ok: bool = True, error: str = "cleanup failed", raises: Optional[Exception] = None, warning: str = "",
                 replace: Optional[dict] = None):
        self.ok, self.error, self.raises, self.warning, self.replace = ok, error, raises, warning, replace or {}
        self.calls: list[dict] = []

    def __call__(self, transcript, cfg, vocab, *, meta=None, render=None, source_sha256="", progress=None, allow_overage=False):
        from mcap import cleanup
        self.calls.append({"transcript": transcript, "meta": meta, "sha": source_sha256, "allow_overage": allow_overage})
        if self.raises:
            raise self.raises
        if not self.ok:
            return cleanup.CleanupResult(False, stats={"batches": 1, "batches_failed": 1}, error_kind="failed", error=self.error,
                                         warning=self.warning)
        segments = [dict(s) for s in transcript["segments"]]
        changed = 0
        for seg in segments:
            for old, new in self.replace.items():
                if old in seg["text"]:
                    seg["raw_text"], seg["text"], seg["cleaned"] = seg["text"], seg["text"].replace(old, new), True
                    changed += 1
        stats = {"batches": 1, "batches_ok": 1, "batches_failed": 0, "changed": changed, "rejected": 0, "ok": True}
        cleaned = {"schema": 1, "derived_from": "transcript.json", "source_sha256": source_sha256, "stats": stats,
                   "languages": transcript.get("languages"), "segments": segments}
        if progress:
            progress(1, 1)
        return cleanup.CleanupResult(True, cleaned, cleanup._render(cleaned, meta or {}, render), stats, warning=self.warning)


class StubVerify:
    """verify_note replacement."""

    def __init__(self, ok: bool = True, error: str = "verification failed", raises: Optional[Exception] = None, warning: str = "",
                 transform=None):
        self.ok, self.error, self.raises, self.warning, self.transform = ok, error, raises, warning, transform
        self.calls: list[dict] = []

    def __call__(self, draft_text, raw_md, cleaned_md, meta, cfg, vocab, allow_overage=False):
        from mcap import verify
        self.calls.append({"draft": draft_text, "raw": raw_md, "cleaned": cleaned_md, "meta": meta, "allow_overage": allow_overage})
        if self.raises:
            raise self.raises
        if not self.ok:
            return verify.VerifyResult(False, error_kind="rejected", error=self.error, warning=self.warning)
        body, footers = verify.split_footer(draft_text)
        final = self.transform(body) if self.transform else body
        stats = {"flagged": 0, "removed": 0, "rewritten": 0, "transcript": "cleaned" if cleaned_md else "raw"}
        text = final.rstrip() + "\n\n" + "\n".join(footers + [verify.applied_footer(stats, "claude-opus-5")]) + "\n"
        return verify.VerifyResult(True, text, stats, warning=self.warning, model="claude-opus-5")


# ---------------------------------------------------------------------------------- organisation policy under test
def _st(kind: str, uid: int, mode: int, size: int = 100) -> SimpleNamespace:
    """An lstat result: ``kind`` file | symlink | directory, owner ``uid``, permission bits ``mode``."""
    import stat as statmod
    bits = {"file": statmod.S_IFREG, "symlink": statmod.S_IFLNK, "directory": statmod.S_IFDIR}[kind]
    return SimpleNamespace(st_mode=bits | mode, st_uid=uid, st_size=size, st_mtime_ns=1_700_000_000_000_000_000, st_ino=4242)


def make_stat_fn(path, *, kind="file", uid=0, mode=0o644, size=None, ancestor_uid=0, ancestor_mode=0o755, ancestor_kind="directory",
                 marker=None, marker_present=False, missing=False, error=None):
    """An lstat stand-in for ``policy.load_org_policy(..., stat_fn=...)``: a test is not root, so the owner, mode and type the loader sees are
    injected. ``path`` is what ``kind/uid/mode/size`` say (root-owned, 0644, a regular file by default), every ancestor directory is
    ``ancestor_*`` (a root-owned 0755 directory; ``ancestor_kind`` file | symlink | directory), ``marker`` exists only when
    ``marker_present``, anything else is not there. ``missing`` makes the file itself absent, ``error`` (an OSError) is raised for it. The
    file CONTENT is read from the real file at ``path``."""
    path = Path(path)
    actual = path.stat().st_size if (path.exists() and size is None) else (size or 0)

    def stat_fn(p):
        p = Path(p)
        if p == path:
            if error is not None:
                raise error
            if missing:
                raise FileNotFoundError(str(p))
            return _st(kind, uid, mode, actual)
        if marker is not None and p == Path(marker):
            if marker_present:
                return _st("file", 0, 0o644)
            raise FileNotFoundError(str(p))
        if p in path.parents:
            return _st(ancestor_kind, ancestor_uid, ancestor_mode)
        raise FileNotFoundError(str(p))
    return stat_fn


def load_test_policy(path, doc, *, version: str = "0.2.0", **stat_kw):
    """Write ``doc`` (a dict, text or bytes) to ``path`` and load it as a root-owned policy through the injected lstat (``stat_kw`` as in
    make_stat_fn). Never sleeps (a locked verdict is not confirmed after 500 ms here). For tests of other packages that need a VALID policy."""
    from mcap import policy as policy_mod
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(doc, bytes):
        path.write_bytes(doc)
    else:
        path.write_text(doc if isinstance(doc, str) else json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    return policy_mod.load_org_policy(path, required_marker=path.parent / "policy.required", stat_fn=make_stat_fn(path, **stat_kw),
                                      current_version=version, sleep=lambda seconds: None)


def afconvert_available() -> bool:
    import shutil
    return bool(shutil.which("afconvert"))


def make_real_m4a(path: Path, seconds: float = 1.0, freq: float = 440.0, rate: int = 16000) -> None:
    """A real (tiny) AAC m4a made with macOS afconvert from a sine wave."""
    import math
    import struct
    import subprocess
    import wave
    wav_path = Path(str(path) + ".tmp.wav")
    with wave.open(str(wav_path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(struct.pack("<h", int(8000 * math.sin(2 * math.pi * freq * i / rate))) for i in range(int(rate * seconds))))
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", str(wav_path), str(path)], check=True, capture_output=True)
    wav_path.unlink()


class TempCase(unittest.TestCase):
    """Base class: a fresh temp root per test, removed afterwards. Also puts a FAKE `security` (MCAP_SECURITY_BIN) in place that
    holds no key: a test that does not expect Keychain access sees `self.security.calls() == []`, and the real Keychain is
    never reachable from these tests. A test that needs a key calls `self.security.store()`."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="mcap-test-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self._tmp_keychain = tempfile.TemporaryDirectory(prefix="mcap-keychain-")      # outside root: the world has no Keychain in it
        self.addCleanup(self._tmp_keychain.cleanup)
        self.security = FakeSecurity(Path(self._tmp_keychain.name) / SECURITY_DIRNAME)
        patcher = mock.patch.dict(os.environ, {"MCAP_SECURITY_BIN": str(self.security.path)})
        patcher.start()
        self.addCleanup(patcher.stop)
