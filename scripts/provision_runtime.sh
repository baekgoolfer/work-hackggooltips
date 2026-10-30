#!/bin/bash
# Verify and activate one release of the COMPANY runtime. Root-owned, signed, switched atomically, never edited.
#
#   scripts/provision_runtime.sh --release-dir DIR [options]
#
# A release is a directory  <root>/<version>/  with  pipeline/  venv/  [models/]  MANIFEST.json  MANIFEST.sig.  <root> is the
# runtime.root of the organisation policy (default /Library/Application Support/MeetingCapture/releases), <version> a name like 0.2.0, and
# <root>/current is a relative symbolic link to the release in use: the app and `mcap` read the pipeline and the python through it.
#
#   MANIFEST.json   every file of the release with its sha256 and mode, every symbolic link with its target (schema 1). Made on the build
#                   host by  --make-manifest.
#   MANIFEST.sig    the Ed25519 signature (64 raw bytes, or the same in base64) of the exact bytes of MANIFEST.json, made OFFLINE with the
#                   release key (the release administrator keeps it; openssl 3 command printed by --make-manifest). The public key (PEM, or 64 hex
#                   characters) is installed on the Mac by the package: <root>/../release-signing.pub.pem.
#
# Modes (one; without one this is a DRY RUN: it verifies and prints what --apply would do, and changes nothing):
#   --sign-macho        (build host, BEFORE --make-manifest) codesign every Mach-O file of DIR (the venv's python, numpy's .so files, ...) with
#                       --identity, the hardened runtime and a secure timestamp: Apple's notary service rejects a package with one unsigned
#                       or ad-hoc signed binary in it. Refused while DIR has a MANIFEST.json (signing changes the hashes it lists).
#   --make-manifest     (build host) write DIR/MANIFEST.json for the tree in DIR and print the offline signing command. Needs no key.
#   --verify-only       verify DIR (signature, hashes, extra files, links, owner, base python) and stop.
#   --check-base HOME   only the base python check, for the folder HOME (the "home =" of a venv's pyvenv.cfg, e.g. <prefix>/bin); needs no release.
#   --apply             verify, make the tree root-owned, switch <root>/current to this release, prune old releases.
#
# Options:
#   --release-dir DIR   the release: <root>/<version>. Its parent is the root, its name the version (digits and dots, 0.2.0).
#   --src SRC           install a release that arrives from outside (an MDM-delivered folder): copy SRC to DIR, verify the COPY, only then
#                       move it into place. DIR must not exist (a release is immutable). Without --src DIR is already in place, as the
#                       package leaves it, and is verified where it is.
#   --pubkey FILE       Ed25519 public key. Default: <root>/../release-signing.pub.pem.
#   --flavor full|client  expected kind (the manifest says which one it is). full has models/, client is the remote-ASR-only venv.
#   --python PATH       interpreter of the verifier. As root only /usr/bin/python3 or a root-owned --python is accepted; the release's OWN
#                       venv is never used (it is what is being verified). Default python3; env MCAP_PYTHON3 does the same.
#   --openssl PATH      check the signature with this OpenSSL 3 instead of the built-in verifier. The stock /usr/bin/openssl of macOS is
#                       LibreSSL and cannot do Ed25519, so this is optional: the built-in RFC 8032 verifier is the default.
#   --keep N            old releases kept besides the new current (default 1: the one that was current before, "N-1"). Only directories
#                       whose names are versions are ever deleted.
#   --identity NAME     --sign-macho: "Developer ID Application: <name> (<TEAMID>)" (your certificate; codesign reads it itself).
#   --entitlements FILE --sign-macho: entitlements for the signed binaries (only an executable reads them). Default none. [unverified] Whether the
#                       venv's python needs any under the hardened runtime (it loads a base python that another team signed) is a device test.
#   --force             --make-manifest: replace an existing MANIFEST.json (and delete the MANIFEST.sig that no longer matches it).
#   -h, --help          this text
#
# Refused, and nothing is activated: a signature that does not match the manifest, a missing or unreadable signature or key, a file whose
# hash differs, a file or link the manifest does not list, a link that leaves the release, a special file, a group- or world-writable file,
# (as root) a file that root does not own, a venv whose BASE PYTHON is missing, writable by group or others (or, as root, not root-owned), a
# version older than the current one.
#
# The base python is what the venv really runs on: its interpreter, its standard library (lib/pythonX.Y with lib-dynload and site-packages) and
# its Python library. It lives OUTSIDE the release (the package does not carry it), so every Mac needs the same base python at the same path
# before the package, and nobody but root may be able to write it (docs/DEPLOY.md 3.1: the python.org installer leaves it root:admin and group
# writable; chown -R root:wheel and chmod -R go-w make it right). Presence and write bits are checked by every run, also as a normal user (the
# build host, --verify-only); the owner (uid 0) is checked only as root. --check-base alone does just that check (the package's preinstall calls it
# BEFORE it puts a personal install aside).
# To go back to an older release use  mcap release switch <version>  (it also checks the minimum version of the policy).
#
# Environment (tests): MCAP_PYTHON3, MCAP_OPENSSL. Root is detected with id -u; a non-root run (a rehearsal in a temp directory) does not
# chown and says so. Nothing here touches a Keychain, starts a process of the app or loads launchd.

set -euo pipefail

RELEASE_DIR=""
SRC=""
PUBKEY=""
FLAVOR=""
PYTHON="${MCAP_PYTHON3:-}"
OPENSSL="${MCAP_OPENSSL:-}"
KEEP=1
FORCE=0
MODE="dry"          # dry | make-manifest | sign-macho | verify-only | apply | check-base
IDENTITY=""
MACHO_ENTITLEMENTS=""
BASE_HOME=""
WORK=""
DIED=0

log()  { echo "[provision_runtime] $*"; }
die()  { DIED=1; echo "[provision_runtime] ERROR: $1" >&2; exit "${2:-1}"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# No ERR trap (it misfires inside $(...) on bash 3.2); an unexpected failure is reported here.
on_exit() {
    local rc=$?
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ]; then
        echo "[provision_runtime] aborted (exit code $rc), see the messages above" >&2
    fi
    return 0
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --release-dir) [ $# -ge 2 ] || die "--release-dir needs a directory" 2; RELEASE_DIR="$2"; shift ;;
        --src) [ $# -ge 2 ] || die "--src needs a directory" 2; SRC="$2"; shift ;;
        --pubkey) [ $# -ge 2 ] || die "--pubkey needs a file" 2; PUBKEY="$2"; shift ;;
        --flavor) [ $# -ge 2 ] || die "--flavor needs full or client" 2; FLAVOR="$2"; shift ;;
        --python) [ $# -ge 2 ] || die "--python needs a path" 2; PYTHON="$2"; shift ;;
        --openssl) [ $# -ge 2 ] || die "--openssl needs a path" 2; OPENSSL="$2"; shift ;;
        --keep) [ $# -ge 2 ] || die "--keep needs a number" 2; KEEP="$2"; shift ;;
        --force) FORCE=1 ;;
        --check-base) [ $# -ge 2 ] || die "--check-base needs a directory (the base python's bin folder)" 2; MODE="check-base"; BASE_HOME="$2"; shift ;;
        --make-manifest) MODE="make-manifest" ;;
        --sign-macho) MODE="sign-macho" ;;
        --identity) [ $# -ge 2 ] || die "--identity needs a name" 2; IDENTITY="$2"; shift ;;
        --entitlements) [ $# -ge 2 ] || die "--entitlements needs a file" 2; MACHO_ENTITLEMENTS="$2"; shift ;;
        --verify-only) MODE="verify-only" ;;
        --apply) MODE="apply" ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" 2 ;;
    esac
    shift
done

if [ "$MODE" = check-base ]; then
    case "$BASE_HOME" in /*) ;; *) die "--check-base needs an absolute path (got '$BASE_HOME')" 2 ;; esac
    [ -n "$RELEASE_DIR" ] || RELEASE_DIR="/nonexistent/0.0"          # not used by this mode, but the checks below want a version-like name
fi
[ -n "$RELEASE_DIR" ] || die "--release-dir is required (try --help)" 2
case "$RELEASE_DIR" in /*) ;; *) die "--release-dir must be an absolute path (got '$RELEASE_DIR')" 2 ;; esac
RELEASE_DIR="${RELEASE_DIR%/}"
ROOT="$(dirname "$RELEASE_DIR")"
VERSION="$(basename "$RELEASE_DIR")"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' || die "the release directory must be named like its version (0.2.0), got '$VERSION'" 2
case "$FLAVOR" in ""|full|client) ;; *) die "--flavor must be full or client" 2 ;; esac
printf '%s' "$KEEP" | grep -Eq '^[0-9]+$' || die "--keep needs a number" 2
if [ -n "$SRC" ]; then
    case "$SRC" in /*) ;; *) die "--src must be an absolute path (got '$SRC')" 2 ;; esac
    [ -d "$SRC" ] || die "--src is not a directory: $SRC" 2
    case "$MODE" in make-manifest|sign-macho) die "--src and --$MODE exclude each other" 2 ;; esac
fi
[ -n "$PUBKEY" ] || PUBKEY="$(dirname "$ROOT")/release-signing.pub.pem"
IS_ROOT=0
[ "$(id -u)" != 0 ] || IS_ROOT=1

# ---- the interpreter that verifies (never the release's own venv) --------------------------------------------------------------
# As root it must be /usr/bin/python3 or a --python that root owns and nobody else can write: the code that decides whether a release may
# run must not be code a user can swap.
root_owned_path() {  # $1 = file or directory: root-owned, not group/other writable, and so is every directory above it
    local p="$1" owner mode
    while [ -n "$p" ] && [ "$p" != "/" ]; do
        owner="$(stat -f %u "$p" 2>/dev/null)" || return 1
        mode="$(stat -f %Lp "$p")"
        [ "$owner" = 0 ] && [ $((8#$mode & 8#022)) -eq 0 ] || return 1
        p="$(dirname "$p")"
    done
    return 0
}

pick_python() {
    local cand="" real=""
    if [ "$IS_ROOT" = 1 ]; then
        if [ -n "$PYTHON" ]; then cand="$PYTHON"; else cand="/usr/bin/python3"; fi
        [ -x "$cand" ] || die "no usable verifier interpreter as root: $cand is missing (install the Command Line Tools, or pass --python <a root-owned python 3.9 or newer>)"
        case "$cand" in
            /usr/bin/python3) ;;                                  # part of the system
            *) real="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
               root_owned_path "$real" || die "--python $cand is not root-owned (or a folder above it is writable): as root the verifier must be code that only root can change" ;;
        esac
    else
        if [ -n "$PYTHON" ]; then cand="$PYTHON"; else cand="$(command -v python3 || true)"; fi
        [ -n "$cand" ] && [ -x "$cand" ] || die "python3 not found: pass --python PATH (any python 3.9 or newer)"
    fi
    "$cand" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1 \
        || die "$cand is not a working python 3.9 or newer (on a Mac without the Command Line Tools /usr/bin/python3 is only a stub: pass --python)"
    PYTHON="$cand"
}

# ---- the verifier and the manifest maker (python, one program, standard library only) ----------------------------------------------
# Subcommands: snapshot, sig-check, tree-check, make-manifest. Exit codes: 0 fine, 10 signature does not match, 11 the tree does not match the
# manifest, 12 bad input (unreadable key, signature or manifest, wrong version). Reasons go to stdout, one per line, at most 30.
py_tool() {
    "$PYTHON" -I - "$@" <<'PYEOF'
import base64, hashlib, json, os, re, stat, sys, time

# ---- Ed25519 verification, RFC 8032 section 6 (the reference code, verification only) -----------------------------------------------
P = 2 ** 255 - 19
Q = 2 ** 252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def inv(x):
    return pow(x, P - 2, P)


def add(a, b):
    A, B = (a[1] - a[0]) * (b[1] - b[0]) % P, (a[1] + a[0]) * (b[1] + b[0]) % P
    C, E = 2 * a[3] * b[3] * D % P, 2 * a[2] * b[2] % P
    E, F, G, H = B - A, E - C, E + C, B + A
    return (E * F % P, G * H % P, F * G % P, E * H % P)


def mul(s, pt):
    out = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            out = add(out, pt)
        pt = add(pt, pt)
        s >>= 1
    return out


def same(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


def decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    x = recover_x(y, sign)
    return None if x is None else (x, y, 1, x * y % P)


_GY = 4 * inv(5) % P
_GX = recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def ed25519_verify(public, msg, sig):
    if len(public) != 32 or len(sig) != 64:
        return False
    a_pt, r_pt = decompress(public), decompress(sig[:32])
    if a_pt is None or r_pt is None:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= Q:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + public + msg).digest(), "little") % Q
    return same(mul(s, G), add(r_pt, mul(h, a_pt)))


SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


def read_public_key(path):
    with open(path, "rb") as fh:
        raw = fh.read(4096)
    text = raw.decode("ascii", "replace")
    m = re.search(r"-----BEGIN PUBLIC KEY-----(.+?)-----END PUBLIC KEY-----", text, re.S)
    if m:
        der = base64.b64decode("".join(m.group(1).split()), validate=False)
        if len(der) == 44 and der.startswith(SPKI_PREFIX):
            return der[12:]
        raise ValueError("the PEM is not an Ed25519 public key")
    hexed = "".join(text.split())
    if re.fullmatch(r"[0-9a-fA-F]{64}", hexed):
        return bytes.fromhex(hexed)
    raise ValueError("the key file is neither a PEM public key nor 64 hex characters")


def read_signature(path):
    with open(path, "rb") as fh:
        raw = fh.read(4096)
    if len(raw) == 64:
        return raw
    try:
        sig = base64.b64decode("".join(raw.decode("ascii").split()), validate=True)
    except Exception:
        sig = b""
    if len(sig) != 64:
        raise ValueError("the signature is not 64 raw bytes nor their base64 text")
    return sig


# ---- the tree --------------------------------------------------------------------------------------------------------------------------
TOP_SKIP = ("MANIFEST.json", "MANIFEST.sig")
VERSION = re.compile(r"[0-9]+(\.[0-9]+){1,3}\Z")


def walk(root):
    """(files {rel: lstat}, links {rel: target}, dirs {rel: lstat}, special [rel]) of the tree, symbolic links never followed."""
    files, links, dirs, special = {}, {}, {}, []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir
        dirs[rel_dir or "."] = os.lstat(dirpath)
        for name in list(dirnames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                dirnames.remove(name)
                links[os.path.join(rel_dir, name)] = os.readlink(full)
        for name in filenames:
            rel = os.path.join(rel_dir, name)
            full = os.path.join(dirpath, name)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                links[rel] = os.readlink(full)
            elif stat.S_ISREG(st.st_mode):
                files[rel] = st
            else:
                special.append(rel)
    for name in TOP_SKIP:
        files.pop(name, None)
    return files, links, dirs, special


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(1 << 20)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def link_inside(rel, target):
    if os.path.isabs(target) or target == "":
        return False
    joined = os.path.normpath(os.path.join(os.path.dirname(rel), target))
    return not (joined == ".." or joined.startswith("../") or os.path.isabs(joined))


def mode_text(st):
    return "%03o" % (stat.S_IMODE(st.st_mode) & 0o777)


def pyvenv_cfg(root):
    """The key = value lines of the venv's pyvenv.cfg ({} when there is none)."""
    out = {}
    try:
        with open(os.path.join(root, "venv", "pyvenv.cfg"), "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                key, sep, value = line.partition("=")
                if sep:
                    out[key.strip()] = value.strip()
    except OSError:
        pass
    return out


def trust_problem(path, owner):
    """None when the real path of ``path`` and every folder above it is not writable by group or others (and, with ``owner``, is owned by
    root), else why not. The group and other write bits are checked whoever runs this; the owner only counts as root. A sticky folder above
    ``path`` (/private/tmp) does not count as writable: nobody can replace what root owns inside it."""
    cur = os.path.realpath(path)
    first = True
    while True:
        try:
            st = os.stat(cur)
        except OSError:
            return "%s cannot be read" % cur
        if owner and st.st_uid != 0:
            return "%s is not owned by root" % cur
        if st.st_mode & 0o022 and (first or not st.st_mode & stat.S_ISVTX):
            return "%s is writable by group or others" % cur
        first = False
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def base_prefix(home, version):
    """(interpreters, prefix, stdlib) of the base python a venv with ``home =`` runs on, found the way python itself finds it: the real
    interpreter files in ``home`` (python, python3, python3.13) and the nearest folder above the first one that has lib/pythonX.Y/os.py.
    ``version`` is the "X.Y" of the venv ("" when unknown: any lib/python3.*). Nothing is executed."""
    try:
        names = sorted(n for n in os.listdir(home) if re.fullmatch(r"python[0-9.]*", n))
    except OSError:
        return [], None, None
    interpreters = [os.path.realpath(os.path.join(home, n)) for n in names]
    for real in interpreters:
        cur = os.path.dirname(real)
        while True:
            lib = os.path.join(cur, "lib")
            try:
                libs = sorted(n for n in os.listdir(lib) if re.fullmatch(r"python3\.[0-9]+", n) and (not version or n == "python" + version))
            except OSError:
                libs = []
            for name in libs:
                if os.path.isfile(os.path.join(lib, name, "os.py")):
                    return interpreters, cur, os.path.join(lib, name)
            parent = os.path.dirname(cur)
            if parent == cur:
                break
            cur = parent
    return interpreters, None, None


FIX = "make the base python root-owned and read-only for others on every Mac (docs/DEPLOY.md 3.1: chown -R root:wheel and chmod -R go-w on it)"


def base_problems(home, version, owner):
    """Everything that makes the base python of a venv untrustworthy, as complete sentences (at most a few lines): missing, an interpreter, the
    folders above the prefix or any file below it that group or others can write (and, as root, that root does not own). Nothing is executed:
    the python that is being judged is never run before it is trusted."""
    if not os.path.isabs(home):
        return ["the venv's base interpreter folder is not an absolute path: %s" % home]
    if not os.path.isdir(home):
        return ["the venv's base python is missing on this Mac: %s. Every Mac needs the same base python at the same path BEFORE the package "
                "is installed (the package does not carry it: docs/DEPLOY.md 3.1)" % home]
    interpreters, prefix, stdlib = base_prefix(home, version)
    if not interpreters:
        return ["the venv's base python folder %s has no python interpreter: the venv cannot run (docs/DEPLOY.md 3.1)" % home]
    if prefix is None:
        return ["the standard library of the venv's base python was not found above %s (no lib/pythonX.Y/os.py): the venv cannot run "
                "(docs/DEPLOY.md 3.1)" % home]
    problems = []
    for real in interpreters:
        why = trust_problem(real, owner)
        if why:
            problems.append("the venv's base interpreter is not trustworthy: %s" % why)
            break
    why = trust_problem(prefix, owner)
    if why:
        problems.append("the venv's base python is not trustworthy: %s" % why)
    found, shown = 0, []
    for dirpath, dirnames, filenames in os.walk(prefix, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            why = None
            if stat.S_ISLNK(st.st_mode):                                    # a link that leaves the prefix is judged like the prefix itself
                target = os.path.realpath(full)
                if target != prefix and not target.startswith(prefix + os.sep):
                    why = trust_problem(target, owner)
                    if why:
                        why = "%s (the target of the link %s)" % (why, full)
            elif owner and st.st_uid != 0:
                why = "%s is not owned by root" % full
            elif st.st_mode & 0o022:
                why = "%s is writable by group or others" % full
            if why:
                found += 1
                if len(shown) < 3:
                    shown.append(why)
    if found:
        problems.append("the venv's base python is not trustworthy: %d path(s) below %s are writable by group or others%s, for example: %s"
                        % (found, prefix, " or not root-owned" if owner else "", "; ".join(shown)))
    if problems:
        problems.append("fix: " + FIX)
    return problems


def cmd_base_check(home, version, owner):
    problems = base_problems(home, version, owner)
    if problems:
        for text in problems:
            print(text)
        return 11
    print("base python %s: present, not writable by group or others%s" % (home, ", root-owned" if owner else " (owner not checked: this is not root)"))
    return 0


def cmd_snapshot(release, outdir):
    for name in TOP_SKIP:
        src = os.path.join(release, name)
        try:
            with open(src, "rb") as fh:
                data = fh.read(64 * 1024 * 1024 + 1)
        except OSError:
            print("%s is missing or unreadable" % name)
            return 12
        if len(data) > 64 * 1024 * 1024:
            print("%s is implausibly large" % name)
            return 12
        fd = os.open(os.path.join(outdir, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(data)
    return 0


def cmd_sig_check(manifest, sig, pubkey):
    try:
        public = read_public_key(pubkey)
        signature = read_signature(sig)
    except (OSError, ValueError) as exc:
        print("cannot use the key or signature: %s" % exc)
        return 12
    with open(manifest, "rb") as fh:
        data = fh.read()
    if not ed25519_verify(public, data, signature):
        print("the signature does not match MANIFEST.json (wrong key, a changed manifest or a damaged signature)")
        return 10
    return 0


def cmd_tree_check(release, manifest_path, version, flavor):
    problems = []

    def bad(text):
        problems.append(text)

    try:
        with open(manifest_path, "rb") as fh:
            manifest = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        print("MANIFEST.json cannot be read: %s" % type(exc).__name__)
        return 12
    if not isinstance(manifest, dict) or manifest.get("schema") != 1:
        print("MANIFEST.json is not schema 1")
        return 12
    if manifest.get("version") != version:
        print("MANIFEST.json is for version %r but the directory is %s" % (manifest.get("version"), version))
        return 12
    if manifest.get("flavor") not in ("full", "client"):
        print("MANIFEST.json has no flavor (full or client)")
        return 12
    if flavor and manifest["flavor"] != flavor:
        print("MANIFEST.json is a %s release but --flavor %s was asked for" % (manifest["flavor"], flavor))
        return 12
    mfiles, mlinks = manifest.get("files"), manifest.get("links", {})
    if not isinstance(mfiles, dict) or not isinstance(mlinks, dict):
        print("MANIFEST.json has no files table")
        return 12
    files, links, dirs, special = walk(release)
    for rel in special:
        bad("special file (not a file, directory or link): %s" % rel)
    for rel, entry in sorted(mfiles.items()):
        st = files.get(rel)
        if st is None:
            bad("missing: %s" % rel)
            continue
        want_mode = entry.get("mode", "") if isinstance(entry, dict) else ""
        if not re.fullmatch(r"[0-7]{3}", want_mode) or int(want_mode, 8) & 0o022:
            bad("the manifest gives %s a mode that group or others can write" % rel)
            continue
        if st.st_mode & 0o022:
            bad("writable by group or others: %s" % rel)
            continue
        if (st.st_mode & 0o111 != 0) != (int(want_mode, 8) & 0o111 != 0):
            bad("executable bit differs: %s" % rel)
            continue
        if sha256_file(os.path.join(release, rel)) != entry.get("sha256"):
            bad("hash differs: %s" % rel)
    for rel in sorted(set(files) - set(mfiles)):
        bad("not in the manifest: %s" % rel)
    for rel, target in sorted(mlinks.items()):
        if rel not in links:
            bad("missing link: %s" % rel)
        elif links[rel] != target:
            bad("link target differs: %s" % rel)
    for rel in sorted(set(links) - set(mlinks)):
        bad("link not in the manifest: %s" % rel)
    for rel, target in sorted(links.items()):
        if not link_inside(rel, target):
            bad("a link leaves the release: %s" % rel)
    for rel in ("pipeline/mcap/__init__.py", "venv/bin/python"):
        if rel not in mfiles and rel not in mlinks:
            bad("the release has no %s" % rel)
    for rel in sorted(dirs):
        if dirs[rel].st_mode & 0o022:
            bad("directory writable by group or others: %s" % rel)
    ownership = "not checked (this is not root)"
    if os.geteuid() == 0:
        ownership = "root-owned"
        for rel, st in list(files.items()) + list(dirs.items()):
            if st.st_uid != 0:
                bad("not owned by root: %s" % rel)
        for rel in links:
            if os.lstat(os.path.join(release, rel)).st_uid != 0:
                bad("link not owned by root: %s" % rel)
    cfg = pyvenv_cfg(release)
    home = cfg.get("home")
    base_note = "none"
    if home:
        resolved = os.path.realpath(home)
        inside = resolved == os.path.realpath(release) or resolved.startswith(os.path.realpath(release) + os.sep)
        if inside:
            base_note = "inside the release"
        else:
            owner = os.geteuid() == 0
            version = ".".join(cfg.get("version", "").split(".")[:2]) if re.match(r"[0-9]+\.[0-9]+", cfg.get("version", "")) else ""
            for text in base_problems(home, version, owner):
                bad(text)
            base_note = "%s, not writable by group or others, %s" % (home, "root-owned" if owner else "owner not checked: this is not root")
    if models_missing(manifest):
        print("note: a full release without a models/ folder: local transcription will not find a model")
    if problems:
        for text in problems[:30]:
            print(text)
        if len(problems) > 30:
            print("... and %d more" % (len(problems) - 30))
        return 11
    print("verified %d files and %d links; owner: %s; base interpreter: %s" % (len(mfiles), len(mlinks), ownership, base_note))
    return 0


def models_missing(manifest):
    return manifest.get("flavor") == "full" and not any(p.startswith("models/") for p in manifest.get("files", {}))


def cmd_make_manifest(release, version, flavor, force):
    out = os.path.join(release, "MANIFEST.json")
    sig = os.path.join(release, "MANIFEST.sig")
    if os.path.lexists(out) and not force:
        print("MANIFEST.json exists already: pass --force to replace it (the signature must be made again)")
        return 12
    files, links, dirs, special = walk(release)
    problems = ["special file: %s" % rel for rel in special]
    for rel, target in sorted(links.items()):
        if not link_inside(rel, target):
            problems.append("a link leaves the release: %s -> %s" % (rel, target))
    for rel, st in files.items():
        if st.st_mode & 0o022:
            problems.append("writable by group or others: %s" % rel)
    if problems:
        for text in problems[:30]:
            print(text)
        if any(text.startswith("writable by group or others") for text in problems):
            print("fix: chmod -R go-w '%s' (docs/DEPLOY.md 3.5: python -m venv leaves some files at 664) and run --make-manifest again" % release)
        return 11
    if not flavor:
        flavor = "full" if any(p.startswith("models/") for p in files) else "client"
    stamp = int(os.environ.get("SOURCE_DATE_EPOCH", "0") or 0) or int(time.time())
    manifest = {
        "schema": 1,
        "version": version,
        "flavor": flavor,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(stamp)),
        "files": {rel: {"sha256": sha256_file(os.path.join(release, rel)), "mode": mode_text(st)} for rel, st in sorted(files.items())},
        "links": dict(sorted(links.items())),
    }
    text = json.dumps(manifest, indent=1, sort_keys=True, ensure_ascii=True) + "\n"
    tmp = out + ".part"
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write(text)
    os.replace(tmp, out)
    if os.path.lexists(sig):
        os.unlink(sig)
        print("removed the old MANIFEST.sig: it did not match the new manifest")
    print("wrote MANIFEST.json: %s release %s, %d files, %d links" % (flavor, version, len(files), len(links)))
    return 0


def main(argv):
    cmd = argv[0]
    if cmd == "snapshot":
        return cmd_snapshot(argv[1], argv[2])
    if cmd == "sig-check":
        return cmd_sig_check(argv[1], argv[2], argv[3])
    if cmd == "tree-check":
        return cmd_tree_check(argv[1], argv[2], argv[3], argv[4])
    if cmd == "make-manifest":
        return cmd_make_manifest(argv[1], argv[2], argv[3], argv[4] == "1")
    if cmd == "base-check":
        return cmd_base_check(argv[1], argv[2], argv[3] == "1")
    print("unknown subcommand %s" % cmd)
    return 12


sys.exit(main(sys.argv[1:]))
PYEOF
}

# ---- verification of one tree --------------------------------------------------------------------------------------------------
# verify_tree <dir>: the signature first (on a private snapshot of manifest and signature, so what was signed is what is checked), then the
# tree against that same snapshot. Dies with the reason; prints the success line.
verify_tree() {
    local dir="$1" snap rc out
    [ -d "$dir" ] || die "release directory not found: $dir"
    [ -f "$PUBKEY" ] || die "public key not found: $PUBKEY (the package installs it; for an out-of-band release pass --pubkey)"
    snap="$WORK/snap.$$.$RANDOM"
    mkdir -m 700 "$snap"
    rc=0; out="$(py_tool snapshot "$dir" "$snap")" || rc=$?
    [ "$rc" = 0 ] || die "release $VERSION refused: $out (a release without MANIFEST.json and MANIFEST.sig is never activated)"
    rc=0
    if [ -n "$OPENSSL" ]; then
        [ -x "$OPENSSL" ] || die "--openssl is not an executable file: $OPENSSL"
        "$OPENSSL" version 2>/dev/null | grep -q '^OpenSSL [3-9]' || die "$OPENSSL is not OpenSSL 3 or newer (LibreSSL cannot verify Ed25519): drop --openssl to use the built-in verifier"
        [ "$(wc -c < "$snap/MANIFEST.sig" | tr -d ' ')" = 64 ] || die "release $VERSION refused: with --openssl the signature must be 64 raw bytes"
        "$OPENSSL" pkeyutl -verify -pubin -inkey "$PUBKEY" -rawin -in "$snap/MANIFEST.json" -sigfile "$snap/MANIFEST.sig" >/dev/null 2>&1 || rc=10
    else
        out="$(py_tool sig-check "$snap/MANIFEST.json" "$snap/MANIFEST.sig" "$PUBKEY")" || rc=$?
    fi
    case "$rc" in
        0) ;;
        10) die "release $VERSION refused: the signature does not match MANIFEST.json (wrong key, a changed manifest or a damaged signature)" ;;
        *) die "release $VERSION refused: ${out:-the signature could not be checked}" ;;
    esac
    rc=0; out="$(py_tool tree-check "$dir" "$snap/MANIFEST.json" "$VERSION" "$FLAVOR")" || rc=$?
    if [ "$rc" != 0 ]; then
        echo "[provision_runtime] release $VERSION refused:" >&2
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        DIED=1
        exit 1
    fi
    printf '%s\n' "$out" | sed 's/^note: /[provision_runtime] note: /; s/^verified /[provision_runtime] release '"$VERSION"': signature OK, verified /'
    rm -rf "$snap"
}

ver_lt() {  # $1 < $2 as tuples of integers
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
        for (i = 1; i <= n; i++) { xi = (i <= na ? x[i] + 0 : 0); yi = (i <= nb ? y[i] + 0 : 0); if (xi < yi) exit 0; if (xi > yi) exit 1 }
        exit 1 }'
}

list_versions() {  # version-named directories of the root, oldest first
    local d name
    [ -d "$ROOT" ] || return 0
    for d in "$ROOT"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [ ! -L "${d%/}" ] || continue
        printf '%s' "$name" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' || continue
        echo "$name"
    done | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n
}

current_version() {
    local t=""
    if [ -L "$ROOT/current" ]; then t="$(readlink "$ROOT/current")"; basename "$t"; fi
}

# KEPT: the versions that survive the prune, as " a b c " (the new one, the one that was current before, and the newest others, --keep old
# releases in all). Activating the version that is current already (a re-run of the package) keeps the newest other release instead.
compute_kept() {
    local v extra="$KEEP"
    KEPT=" $VERSION "
    if [ "$extra" -gt 0 ] && [ -n "$OLD" ] && [ "$OLD" != "$VERSION" ]; then
        KEPT="$KEPT$OLD "
        extra=$((extra - 1))
    fi
    for v in $(list_versions | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr); do
        [ "$extra" -gt 0 ] || break
        case "$KEPT" in *" $v "*) continue ;; esac
        KEPT="$KEPT$v "
        extra=$((extra - 1))
    done
}

make_root_owned() {  # $1 = tree
    if [ "$IS_ROOT" = 1 ]; then
        chown -R root:wheel "$1"
        chmod -R go-w "$1"
        log "owner of $1 set to root:wheel, no write for group or others"
    else
        log "not root: ownership of $1 not changed (a rehearsal; a real install runs as root and verifies it)"
    fi
}

# ---- modes ---------------------------------------------------------------------------------------------------------------------------
macho_files() {  # $1 = tree: every Mach-O file below it (found by content, not by name or mode), one path per line
    find "$1" -type f -print0 | xargs -0 file 2>/dev/null | sed -n 's/: *Mach-O .*$//p'
}

case "$MODE" in
    check-base)
        pick_python
        rc=0; out="$(py_tool base-check "$BASE_HOME" "" "$IS_ROOT")" || rc=$?
        printf '%s\n' "$out" | sed 's/^/[provision_runtime] /'
        [ "$rc" = 0 ] || die "the base python is not fit for a company release" "$rc"
        exit 0 ;;
    sign-macho)
        [ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR"
        [ -n "$IDENTITY" ] || die "--sign-macho needs --identity 'Developer ID Application: <name> (<TEAMID>)'" 2
        [ ! -e "$RELEASE_DIR/MANIFEST.json" ] || die "$RELEASE_DIR/MANIFEST.json exists: signing changes the files it lists. Sign FIRST, then --make-manifest (to sign a release that was made already, remove MANIFEST.json and MANIFEST.sig)"
        if [ -n "$MACHO_ENTITLEMENTS" ]; then
            [ -f "$MACHO_ENTITLEMENTS" ] && plutil -lint "$MACHO_ENTITLEMENTS" >/dev/null || die "--entitlements is not a valid plist file: $MACHO_ENTITLEMENTS"
        fi
        CODESIGN_ARGS=(--force --options runtime --timestamp)
        [ -z "$MACHO_ENTITLEMENTS" ] || CODESIGN_ARGS+=(--entitlements "$MACHO_ENTITLEMENTS")
        signed=0
        while IFS= read -r f; do
            codesign "${CODESIGN_ARGS[@]}" --sign "$IDENTITY" "$f" || die "codesign failed on $f (nothing after it was signed: run again)"
            signed=$((signed + 1))
        done < <(macho_files "$RELEASE_DIR")
        [ "$signed" -gt 0 ] || die "no Mach-O file below $RELEASE_DIR: is this the release folder (venv/, pipeline/, models/)?"
        log "signed $signed Mach-O file(s) of $RELEASE_DIR with '$IDENTITY', the hardened runtime and a secure timestamp"
        log "next: --make-manifest, then the offline signature of MANIFEST.json (docs/DEPLOY.md 3.5); build_pkg.sh --app-identity refuses a payload with a Mach-O file that is not signed like this"
        exit 0 ;;
    make-manifest)
        [ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR"
        pick_python
        rc=0; out="$(py_tool make-manifest "$RELEASE_DIR" "$VERSION" "$FLAVOR" "$FORCE")" || rc=$?
        printf '%s\n' "$out" | sed 's/^/[provision_runtime] /'
        [ "$rc" = 0 ] || die "no manifest written" "$rc"
        cat <<EOS
[provision_runtime] next, OFFLINE, on the machine that holds the release key (OpenSSL 3 or newer; the /usr/bin/openssl of macOS is LibreSSL and cannot sign Ed25519):
[provision_runtime]   openssl pkeyutl -sign -inkey <release-signing.key> -rawin -in '$RELEASE_DIR/MANIFEST.json' -out '$RELEASE_DIR/MANIFEST.sig'
[provision_runtime] the public half goes into the package:  scripts/build_pkg.sh --release-dir '$RELEASE_DIR' --release-pubkey <release-signing.pub.pem>
[provision_runtime]   (make the pair once:  openssl genpkey -algorithm ed25519 -out release-signing.key  and  openssl pkey -in release-signing.key -pubout -out release-signing.pub.pem)
EOS
        exit 0 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcap-provision.XXXXXX")"
pick_python
TARGET_TREE="$RELEASE_DIR"
[ -z "$SRC" ] || TARGET_TREE="$SRC"
if [ -z "$SRC" ]; then
    [ -d "$RELEASE_DIR" ] || die "release directory not found: $RELEASE_DIR (give --src to install one from another folder)"
else
    [ ! -e "$RELEASE_DIR" ] || die "release $VERSION exists already at $RELEASE_DIR: releases are immutable. Use a new version, or remove that folder yourself first"
fi

OLD="$(current_version)"
if [ -n "$OLD" ] && ver_lt "$VERSION" "$OLD"; then
    die "refusing to activate $VERSION: it is older than the current release $OLD. To go back use  mcap release switch $VERSION  (it also checks the minimum version of the policy)"
fi
if [ -e "$ROOT/current" ] && [ ! -L "$ROOT/current" ]; then
    die "$ROOT/current exists and is not a symbolic link: refusing to replace it"
fi

case "$MODE" in
    dry)         log "DRY RUN: nothing is changed. Add --apply to activate, --verify-only to only check." ;;
    verify-only) log "verifying $TARGET_TREE" ;;
    apply)       log "APPLY: release $VERSION into $ROOT" ;;
esac

if [ "$MODE" != apply ]; then
    verify_tree "$TARGET_TREE"
    if [ "$MODE" = dry ]; then
        log "would: ${SRC:+copy $SRC to $RELEASE_DIR, }make the tree root-owned, switch $ROOT/current: ${OLD:-(none)} -> $VERSION"
        compute_kept
        log "would keep:${KEPT}(the new current and $KEEP older release(s): the one that was current, then the newest others)"
        for v in $(list_versions); do
            case "$KEPT" in *" $v "*) continue ;; esac
            log "would delete the old release $ROOT/$v"
        done
        log "DRY RUN finished: nothing was changed."
    fi
    exit 0
fi

# --apply ------------------------------------------------------------------------------------------------------------------------------
mkdir -p "$ROOT"
IN_PLACE="$RELEASE_DIR"
if [ -n "$SRC" ]; then
    INCOMING="$ROOT/.incoming.$VERSION.$$"
    log "copying $SRC to $INCOMING"
    cp -R "$SRC" "$INCOMING"
    IN_PLACE="$INCOMING"
fi
make_root_owned "$IN_PLACE"
if ! ( verify_tree "$IN_PLACE" ); then
    [ -z "$SRC" ] || rm -rf "$INCOMING"
    DIED=1
    exit 1
fi
if [ -n "$SRC" ]; then
    mv "$INCOMING" "$RELEASE_DIR"
    log "release $VERSION is in place: $RELEASE_DIR"
fi
if [ "$IS_ROOT" = 1 ]; then chown root:wheel "$ROOT"; fi
chmod 755 "$ROOT"

# the atomic switch: a new symbolic link is made next to the old one and renamed over it, so a reader sees the old release or the new one, never none
if [ "$OLD" = "$VERSION" ]; then
    log "current already points to $VERSION"
else
    ln -s "$VERSION" "$ROOT/.current.$$"
    mv -h -f "$ROOT/.current.$$" "$ROOT/current"
    log "switched $ROOT/current: ${OLD:-(none)} -> $VERSION (a job that is already running keeps the release it started with)"
fi

# prune: keep the new current, the one that was current before (N-1), and --keep minus one more of the newest others
compute_kept
for v in $(list_versions); do
    case "$KEPT" in *" $v "*) continue ;; esac
    case "$ROOT/$v" in
        "$ROOT"/[0-9]*) rm -rf "${ROOT:?}/$v"; log "pruned old release $v" ;;
    esac
done
if [ -n "$OLD" ] && [ "$OLD" != "$VERSION" ]; then
    log "done. current -> $VERSION, the previous release $OLD is kept (go back with: mcap release switch $OLD)"
else
    log "done. current -> $VERSION"
fi
