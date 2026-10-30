#!/bin/bash
# Write an organisation policy.json (schema 1, docs/POLICY.md) that the pipeline accepts, and check one that exists.
#
#   scripts/make_policy.sh [options] [--out FILE]      write a policy (default: print it)
#   scripts/make_policy.sh --check FILE                 load FILE with the pipeline's own loader and say valid or locked (and why)
#
# With no option it writes the BASELINE the company package installs on every Mac: profile company, every external lane deny, nothing
# approved, local_only.default true, the company enforced values (LOG_CONTENT=0, ASR_ALLOW_DOWNLOAD=0, MIC_MUTE_GATE=on, NOTIFY_RECORDING=1),
# the defaults LOG_RETENTION_DAYS=30 and APP_LOG_MAX_MB=5, the local Whisper model of the release as ASR_MODEL, archive.allowed_roots on the
# team shared drive, runtime.root on the root-owned releases. Opening something is an explicit act, one lane at a time, in a new revision:
#
#   scripts/make_policy.sh --revision 2 --allow drive=TICKET-1234 --out policy.json
#
# Options (all repeatable ones say so):
#   --profile company|personal   default company
#   --revision N                 positive integer (default 1); raise it with every change
#   --issued TEXT                issue time (default: now, ISO 8601 with the offset)
#   --min-pipeline-version V     default 0.2.0 (the Swift app requires at least that whenever a policy exists)
#   --contact TEXT               support.contact, one line of at most 60 characters (shown in notifications)
#   --ring NAME / --note TEXT    ext.ring / ext.note: free metadata, ignored by both parsers
#   --allow LANE[=REFERENCE]     open a lane (repeatable): asr_remote, asr_cloud, llm, calendar, drive. In the company profile every lane except
#                                asr_remote needs an approval reference (ticket or legal sign-off, at most 80 characters): --allow drive=TICKET-1
#                                REFUSED without it, and --allow llm also needs --claude-team-id or --claude-sha256. --allow asr_remote adds the
#                                engine remote to --engine, --allow asr_cloud adds azure, when you did not name engines yourself.
#   --local-only-default | --no-local-only-default    local_only.default (company baseline: on, personal: off)
#   --local-only-locked          local_only.locked: the flag is always on and the app's menu item is disabled (clinical device groups)
#   --recording-off              recording.enabled=false: the kill switch
#   --engine ID                  asr.allowed_engines (repeatable; default whisper)
#   --host NAME                  asr.allowed_hosts, exact DNS names (repeatable; default none)
#   --allow-foreign              asr.allow_foreign
#   --daily-minutes N            asr.daily_audio_minutes_cap (default 240)
#   --send-vocab-cloud           asr.send_vocab.cloud true (company default false)
#   --org-consent SPEC           an organisation consent for a server engine (repeatable): engine=remote,host=NAME,port=443,ca_sha256=HEX64,
#                                attest=HEX64[+HEX64...],use=both|primary|fallback,expires=YYYY-MM-DD[,protocol=mcap-asr/1]
#   --archive-root PATH          archive.allowed_roots (repeatable; default ~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings: replace example.com with your Workspace domain)
#   --local-root PATH            archive.local_roots (repeatable)
#   --claude-team-id ID | --claude-sha256 HEX    llm.claude_bin_pin: the signature the claude CLI must have (the administrator supplies it)
#   --runtime-root DIR           runtime.root (default /Library/Application Support/MeetingCapture/releases)
#   --asr-model PATH             defaults.ASR_MODEL (default <runtime root>/current/models/whisper-large-v3-mlx)
#   --client-only                the release has no local model (and no mlx): no ASR_MODEL default, and defaults.ASR_ENGINE=remote instead of whisper,
#                                because a Mac that cannot run Whisper must not be told to try it (an explicit whisper is never replaced by the
#                                pipeline). The relay stays closed until --allow asr_remote; it also needs where it is:
#                                  --default ASR_REMOTE_URL=https://asr.example.internal --default ASR_REMOTE_CA_FILE=/Library/Application\ Support/MeetingCapture/asr-ca.pem
#                                (the host of the URL is --host and the org consent's host; the PEM is delivered by MDM, its sha256 is the consent's
#                                ca_sha256: docs/DEPLOY.md 7)
#   --default KEY=VALUE          defaults layer (repeatable; whitelisted behavioural keys only, checked by the loader)
#   --enforce KEY=VALUE          enforced layer (repeatable)
#   --out FILE                   write the policy here, atomically, mode 0644 (default: stdout)
#   --check FILE                 validate FILE instead (content only: owner, mode and ancestors are checked on the Mac itself)
#   -h, --help                   this text
#
# Whatever is written has been loaded with pipeline/mcap/policy.py first (load_org_policy), with the owner of the file and its folders
# presented as root, which is how a package or MDM installs it. A policy that would be locked is never written. The script reads no
# Keychain, opens no socket, and writes only --out. Environment: MCAP_PYTHON3 (default python3, 3.9 or newer).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_DIR="${MCAP_PIPELINE_DIR:-$SCRIPT_DIR/../pipeline}"
PYTHON="${MCAP_PYTHON3:-python3}"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
for a in "$@"; do
    case "$a" in -h|--help) usage; exit 0 ;; esac
done
[ -f "$PIPELINE_DIR/mcap/policy.py" ] || { echo "[make_policy] ERROR: pipeline/mcap/policy.py not found under $PIPELINE_DIR" >&2; exit 1; }
command -v "$PYTHON" >/dev/null 2>&1 || { echo "[make_policy] ERROR: $PYTHON not found (python 3.9 or newer; MCAP_PYTHON3 names another)" >&2; exit 1; }

exec "$PYTHON" -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
sys.argv = ["make_policy.sh"] + sys.argv[2:]
exec(compile(sys.stdin.read(), "make_policy.sh", "exec"))
' "$PIPELINE_DIR" "$@" <<'PYEOF'
import argparse, json, os, re, sys, tempfile
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
import stat as statmod

from mcap import __version__, policy

LANES = policy.LANES
APPROVAL_LANES = policy.APPROVAL_LANES
HEX64 = re.compile(r"[0-9a-fA-F]{64}\Z")
DEFAULT_RUNTIME_ROOT = "/Library/Application Support/MeetingCapture/releases"
DEFAULT_ARCHIVE_ROOT = "~/Library/CloudStorage/GoogleDrive-*@example.com/Shared drives/Meetings"


def fail(text, code=2):
    print("[make_policy] ERROR: " + text, file=sys.stderr)
    sys.exit(code)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        fail(message + " (try --help)")


def as_root(path):
    """An lstat stand-in presenting `path` as a root-owned 0644 regular file in root-owned 0755 folders (what a package installs)."""
    path = Path(path)
    size = path.stat().st_size

    def st(kind, mode, size=100):
        bits = {"file": statmod.S_IFREG, "directory": statmod.S_IFDIR}[kind]
        return SimpleNamespace(st_mode=bits | mode, st_uid=0, st_size=size, st_mtime_ns=1_700_000_000_000_000_000, st_ino=4242)

    def stat_fn(p):
        p = Path(p)
        if p == path:
            return st("file", 0o644, size)
        if p in path.parents:
            return st("directory", 0o755)
        raise FileNotFoundError(str(p))
    return stat_fn


def load(path):
    path = Path(path).resolve()
    return policy.load_org_policy(path, required_marker=path.parent / "no-such-marker", stat_fn=as_root(path), current_version=__version__,
                                  sleep=lambda s: None)


def describe(pol):
    if pol.locked:
        return "locked: %s" % pol.locked_reason
    lanes = ", ".join("%s=%s" % (lane, pol.lanes[lane]) for lane in LANES)
    return "valid: profile %s, revision %s, sha256 %s, lanes %s, local_only default %s locked %s" % (
        pol.profile, pol.revision, pol.sha256_8, lanes, pol.local_only_default, pol.local_only_locked)


def parse_kv(text, what):
    if "=" not in text:
        fail("%s needs KEY=VALUE, got %r" % (what, text))
    key, _, value = text.partition("=")
    return key.strip(), value


def parse_consent(spec):
    fields = {}
    for part in spec.split(","):
        key, value = parse_kv(part, "--org-consent")
        fields[key.strip()] = value.strip()
    allowed = {"engine", "host", "port", "ca_sha256", "attest", "use", "expires", "protocol", "backend_kind"}
    unknown = set(fields) - allowed
    if unknown:
        fail("--org-consent: unknown field(s) %s" % ", ".join(sorted(unknown)))
    for need in ("engine", "host", "ca_sha256", "attest", "use", "expires"):
        if need not in fields:
            fail("--org-consent needs %s=" % need)
    builds = [b for b in fields["attest"].split("+") if b]
    if not HEX64.match(fields["ca_sha256"]) or not builds or any(not HEX64.match(b) for b in builds):
        fail("--org-consent: ca_sha256 and every attest value are 64 hex characters (attest values are joined with +)")
    try:
        port = int(fields.get("port", "443"))
    except ValueError:
        fail("--org-consent: port is a number")
    return {"engine": fields["engine"], "host": fields["host"].lower(), "port": port, "protocol": fields.get("protocol", "mcap-asr/1"),
            "backend_kind": fields.get("backend_kind", "server"), "ca_sha256": fields["ca_sha256"].lower(),
            "attest_build_sha256": [b.lower() for b in builds], "use": fields["use"], "expires": fields["expires"]}


COMPANY_ONLY = ("allow", "engine", "host", "org_consent", "archive_root", "local_root", "claude_team_id", "claude_sha256", "asr_model")


def build_personal(args):
    """The personal profile allows every lane and every engine it does not restrict (docs/POLICY.md 4): the document only carries what it
    sets, and the options that open or list company things are refused instead of being written as restrictions nobody asked for."""
    named = [name.replace("_", "-") for name in COMPANY_ONLY if getattr(args, name)]
    if args.runtime_root != DEFAULT_RUNTIME_ROOT:
        named.append("runtime-root")
    if args.client_only:
        named.append("client-only")
    if args.allow_foreign or args.send_vocab_cloud or args.daily_minutes != 240:
        named.append("allow-foreign/send-vocab-cloud/daily-minutes")
    if named:
        fail("--profile personal does not take --%s: a personal policy allows every lane it does not restrict, there is nothing to open or "
             "list (use --profile company)" % ", --".join(named))
    doc = {"schema": 1, "profile": "personal", "revision": args.revision,
           "issued": args.issued or datetime.now().astimezone().isoformat(timespec="seconds"),
           "min_pipeline_version": args.min_pipeline_version}
    if args.contact:
        doc["support"] = {"contact": args.contact}
    doc["local_only"] = {"default": args.local_only_default, "locked": args.local_only_locked}
    doc["recording"] = {"enabled": not args.recording_off}
    layers = {"defaults": {}, "enforced": {}}
    for name, items in (("defaults", args.default), ("enforced", args.enforce)):
        for item in items:
            key, value = parse_kv(item, "--default" if name == "defaults" else "--enforce")
            layers[name][key] = value
    for name in ("defaults", "enforced"):
        if layers[name]:
            doc[name] = layers[name]
    ext = {}
    if args.ring:
        ext["ring"] = args.ring
    if args.note:
        ext["note"] = args.note
    doc["ext"] = ext
    return doc


def build(args):
    if args.profile == "personal":
        return build_personal(args)
    company = True
    lanes = {lane: "deny" for lane in LANES}
    approvals = {}
    engines = list(args.engine) if args.engine else None
    for item in args.allow:
        lane, _, ref = item.partition("=")
        lane, ref = lane.strip(), ref.strip()
        if lane not in LANES:
            fail("--allow %s: not a lane (%s)" % (lane, ", ".join(LANES)))
        if company and lane in APPROVAL_LANES:
            if not ref:
                fail("--allow %s needs an approval reference in the company profile: --allow %s=<ticket or sign-off id> "
                     "(docs/POLICY.md 5.1). A lane is never opened without a recorded approval." % (lane, lane))
            if len(ref) > 80 or any(ord(c) < 32 for c in ref):
                fail("--allow %s: the approval reference is one line of at most 80 characters" % lane)
            approvals[lane] = ref
        elif ref:
            if lane not in APPROVAL_LANES:
                fail("--allow %s takes no approval reference (only %s do)" % (lane, ", ".join(APPROVAL_LANES)))
            approvals[lane] = ref
        lanes[lane] = "allow"
    if lanes["llm"] == "allow" and company and not (args.claude_team_id or args.claude_sha256):
        fail("--allow llm needs --claude-team-id or --claude-sha256: the company profile only opens the llm lane for a claude CLI whose "
             "signature is pinned (docs/POLICY.md). The administrator supplies the value; it is not guessed here.")
    if engines is None:
        engines = ["whisper"]
        if lanes["asr_remote"] == "allow":
            engines.append("remote")
        if lanes["asr_cloud"] == "allow":
            engines.append("azure")
    root = args.runtime_root.rstrip("/") or "/"
    doc = {"schema": 1, "profile": args.profile, "revision": args.revision,
           "issued": args.issued or datetime.now().astimezone().isoformat(timespec="seconds"),
           "min_pipeline_version": args.min_pipeline_version}
    if args.contact:
        doc["support"] = {"contact": args.contact}
    doc["lanes"] = lanes
    doc["approvals"] = approvals
    doc["local_only"] = {"default": args.local_only_default, "locked": args.local_only_locked}
    doc["recording"] = {"enabled": not args.recording_off}
    asr = {"allowed_engines": engines, "allowed_hosts": [h.lower() for h in args.host], "allow_foreign": bool(args.allow_foreign),
           "daily_audio_minutes_cap": args.daily_minutes,
           "send_vocab": {"server": True, "cloud": bool(args.send_vocab_cloud)},
           "org_consents": [parse_consent(spec) for spec in args.org_consent]}
    doc["asr"] = asr
    doc["archive"] = {"allowed_roots": args.archive_root or [DEFAULT_ARCHIVE_ROOT], "local_roots": list(args.local_root)}
    llm = {"child_env": {}}
    if args.claude_team_id:
        llm["claude_bin_pin"] = {"team_id": args.claude_team_id}
    elif args.claude_sha256:
        llm["claude_bin_pin"] = {"sha256": args.claude_sha256.lower()}
    doc["llm"] = llm
    doc["runtime"] = {"root": root}
    defaults = {"ASR_ENGINE": "remote" if args.client_only else "whisper", "LOG_RETENTION_DAYS": "30", "APP_LOG_MAX_MB": "5"}
    if not args.client_only:
        defaults["ASR_MODEL"] = args.asr_model or (root + "/current/models/whisper-large-v3-mlx")
    for item in args.default:
        key, value = parse_kv(item, "--default")
        defaults[key] = value
    enforced = {"LOG_CONTENT": "0", "ASR_ALLOW_DOWNLOAD": "0", "MIC_MUTE_GATE": "on", "NOTIFY_RECORDING": "1"}
    for item in args.enforce:
        key, value = parse_kv(item, "--enforce")
        enforced[key] = value
    doc["defaults"] = defaults
    doc["enforced"] = enforced
    ext = {}
    if args.ring:
        ext["ring"] = args.ring
    if args.note:
        ext["note"] = args.note
    doc["ext"] = ext
    return doc


def main():
    p = Parser(prog="make_policy.sh", add_help=False)
    p.add_argument("--check", metavar="FILE")
    p.add_argument("--out", metavar="FILE")
    p.add_argument("--profile", choices=["company", "personal"], default="company")
    p.add_argument("--revision", type=int, default=1)
    p.add_argument("--issued")
    p.add_argument("--min-pipeline-version", default="0.2.0")
    p.add_argument("--contact")
    p.add_argument("--ring")
    p.add_argument("--note")
    p.add_argument("--allow", action="append", default=[])
    p.add_argument("--local-only-default", dest="local_only_default", action="store_true", default=None)
    p.add_argument("--no-local-only-default", dest="local_only_default", action="store_false")
    p.add_argument("--local-only-locked", action="store_true")
    p.add_argument("--recording-off", action="store_true")
    p.add_argument("--engine", action="append", default=[])
    p.add_argument("--host", action="append", default=[])
    p.add_argument("--allow-foreign", action="store_true")
    p.add_argument("--daily-minutes", type=int, default=240)
    p.add_argument("--send-vocab-cloud", action="store_true")
    p.add_argument("--org-consent", action="append", default=[])
    p.add_argument("--archive-root", action="append", default=[])
    p.add_argument("--local-root", action="append", default=[])
    p.add_argument("--claude-team-id")
    p.add_argument("--claude-sha256")
    p.add_argument("--runtime-root", default=DEFAULT_RUNTIME_ROOT)
    p.add_argument("--asr-model")
    p.add_argument("--client-only", action="store_true")
    p.add_argument("--default", action="append", default=[])
    p.add_argument("--enforce", action="append", default=[])
    args = p.parse_args()

    if args.check:
        if not os.path.isfile(args.check):
            fail("--check: not a file: %s" % args.check)
        pol = load(args.check)
        print(describe(pol))
        return 0 if not pol.locked else 1
    if args.revision < 1:
        fail("--revision is a positive integer")
    if args.local_only_default is None:
        args.local_only_default = args.profile == "company"      # the baseline starts every meeting local-only; a personal policy does not
    if args.claude_team_id and args.claude_sha256:
        fail("--claude-team-id and --claude-sha256 exclude each other")
    doc = build(args)
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    fd, tmp_path = tempfile.mkstemp(prefix="mcap-policy.", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        pol = load(tmp_path)
        if pol.locked:
            fail("the policy would be LOCKED by the loader (%s): nothing was written. Fix the option it names." % pol.locked_reason, 1)
    finally:
        os.unlink(tmp_path)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        part = out.with_name(out.name + ".part")
        with open(part, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.chmod(part, 0o644)
        os.replace(part, out)
        print("[make_policy] wrote %s: %s" % (out, describe(pol)), file=sys.stderr)
    else:
        sys.stdout.write(text)
        print("[make_policy] " + describe(pol), file=sys.stderr)
    return 0


sys.exit(main())
PYEOF
