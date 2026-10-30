#!/bin/bash
# Create ONE fixed, self-signed code-signing identity named "MeetingCapture Local Signing" in YOUR login keychain.
# You run this yourself, once. Why: with a fixed identity the macOS permissions (Microphone, System Audio Recording,
# Notifications; Chrome automation only if Google Meet is enabled) are tied to  identifier "<bundle id>" + this
# certificate  instead of to the code hash, so they survive every rebuild. The bundle id is MCAP_BUNDLE_ID (default org.meetingcapture.app, as for
# scripts/build_app.sh): the self-test below signs with the id your next build will have, so run this with the same MCAP_BUNDLE_ID. With the ad-hoc signature every changed build asks again.
# The identity name is the label of a certificate in YOUR keychain, not the name of the app: it stays "MeetingCapture Local Signing" so that an identity made
# earlier is still found by scripts/build_app.sh (the app names are MCAP_APP_NAME and MCAP_APP_SHORT_NAME there).
#
#   scripts/make_signing_identity.sh --dry-run     look first: shows the plan, creates nothing in the keychain
#   scripts/make_signing_identity.sh               create it (idempotent: an existing identity is kept)
#   scripts/make_signing_identity.sh --trust       same, and ALSO set the trust (only if codesign refuses, see below)
#
# What it does (nothing else):
#   1. openssl (in a private temp directory, deleted afterwards) makes a 2048-bit RSA key and a self-signed certificate
#      with the Code Signing extended key usage, valid 10 years, and a throw-away random password for the PKCS#12 file.
#   2. security import ... -k <login keychain> -T /usr/bin/codesign   adds that certificate + key to your login keychain
#      (only /usr/bin/codesign may use the key without asking).
#   3. Self-test: signs a temporary COPY of /usr/bin/true with the identity, verifies it and prints the designated
#      requirement, i.e. the exact string macOS will store for the app's permissions. Nothing else is signed.
#   macOS may show its own dialogs: unlock the login keychain, and "codesign wants to sign using key ...". Type your
#   login password into THOSE dialogs and choose "Always Allow". This script never asks for, reads or stores your password.
#
# Security trade-off (read it before you run this; the README repeats it under "Privacy & trade-offs"):
#   - the private key lives in your login keychain and /usr/bin/codesign may use it WITHOUT a prompt, so any process running as
#     you can sign code with this identity;
#   - what is signed with it has the same designated requirement as the app (<short name>.app), so it inherits the permissions you
#     granted the app (microphone, system audio recording, ...). If macOS needs the trust step below, that trust is also yours only;
#   - the app is signed WITHOUT the hardened runtime, so a library can be injected into it by a process running as you.
#   For a one-person Mac this is the price of not re-approving the permissions after every rebuild. The alternative (no identity,
#   ad-hoc signature) has none of these risks and costs you that re-approval; delete the identity again any time (below).
#
# Is a trust setting needed? Unknown until tried: macOS may refuse to sign with an untrusted self-signed certificate
# ("no identity found"). So the script tries first. Only if codesign refuses it prints the follow-up, which needs
# --trust:
#       security add-trusted-cert -r trustRoot -p codeSign <certificate.pem>
#   That opens a macOS password dialog ("You are making changes to your Certificate Trust Settings") and records, for
#   YOUR USER ACCOUNT only (not system-wide, no admin domain), that this one certificate is trusted for the Code Signing
#   policy. It changes nothing about other certificates, Gatekeeper or other apps. Undo: security remove-trusted-cert.
#   With --trust the trust step is still skipped when signing already works without it.
#
# Options:
#   --dry-run          generate a throw-away certificate in a temp directory to prove openssl works here, then print every
#                      command that would touch the keychain; the keychain is only READ (security find-identity)
#   --trust            allow the user-domain trust step if (and only if) the self-test is refused
#   --export-only DIR  only write MeetingCapture-Local-Signing.p12 and cert.pem into the (new) directory DIR and print the
#                      one-time password, for importing by hand in Keychain Access. Touches no keychain.
#   -h, --help         this text
#
# Exit codes: 0 identity ready and signing works; 1 error; 2 usage; 3 identity exists but codesign refuses to use it
# (the message says what to do).
#
# Remove it again (certificate + private key + its trust setting):
#   security delete-identity -c "MeetingCapture Local Signing" -t ~/Library/Keychains/login.keychain-db
#   or: Keychain Access > login > My Certificates > MeetingCapture Local Signing > Delete.
# Afterwards scripts/build_app.sh signs ad-hoc again.
#
# Environment (tests): MCAP_OPENSSL=<openssl binary> (default /usr/bin/openssl = LibreSSL, then the one in PATH).

set -euo pipefail
umask 077

# shellcheck source=bundle_id.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bundle_id.sh"

IDENTITY_NAME="MeetingCapture Local Signing"
CERT_DAYS=3650
P12_FILE_NAME="MeetingCapture-Local-Signing.p12"
CERT_FILE_NAME="MeetingCapture-Local-Signing.cert.pem"

DRY_RUN=0
ALLOW_TRUST=0
EXPORT_DIR=""
TMP_DIR=""
DIED=0
OPENSSL=""
KEYCHAIN=""
CERT_SHA1=""
P12_PASS=""
HASH=""

log()  { echo "[signing] $*"; }
warn() { echo "[signing] WARNING: $*" >&2; }
die()  { DIED=1; echo "[signing] ERROR: $*" >&2; exit 1; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
# The temp directory holds the private key: it is always removed, also on Ctrl-C.
on_exit() {
    local rc=$?
    [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
    if [ "$rc" -ne 0 ] && [ "$DIED" != 1 ] && [ "$rc" -ne 3 ]; then
        echo "[signing] aborted (exit code $rc), see the messages above. The temporary files were deleted." >&2
    fi
    return 0
}
trap on_exit EXIT
trap 'DIED=1; echo "[signing] interrupted" >&2; exit 130' INT TERM

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --trust) ALLOW_TRUST=1 ;;
        --export-only) [ $# -ge 2 ] || { echo "--export-only needs a directory" >&2; exit 2; }; EXPORT_DIR="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[signing] unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done
[ -z "$EXPORT_DIR" ] || [ "$DRY_RUN" = 0 ] || { echo "[signing] --export-only and --dry-run exclude each other" >&2; exit 2; }
[ -z "$EXPORT_DIR" ] || [ "$ALLOW_TRUST" = 0 ] || { echo "[signing] --export-only never touches the keychain, so --trust makes no sense with it" >&2; exit 2; }

# ---- preflight -----------------------------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "this is for macOS"
BUNDLE_ID="$(mcap_resolve_bundle_id)" || die "the bundle identifier is refused (see above). Nothing was changed."
APP_NAME="$(mcap_resolve_app_name)" || die "the app name is refused (see above). Nothing was changed."              # only for the texts below: they name the app
APP_SHORT_NAME="$(mcap_resolve_app_short_name)" || die "the short app name is refused (see above). Nothing was changed."
[ "$(id -u)" != 0 ] || die "do not run this as root: the identity belongs in YOUR login keychain"
for tool in mktemp sed awk cp; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
if [ -z "$EXPORT_DIR" ]; then
    for tool in security codesign; do
        command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool (it ships with macOS / the Command Line Tools)"
    done
fi
if [ -n "${MCAP_OPENSSL:-}" ]; then
    OPENSSL="$MCAP_OPENSSL"
elif [ -x /usr/bin/openssl ]; then
    OPENSSL=/usr/bin/openssl      # LibreSSL: its PKCS#12 files are what macOS 'security import' reads
elif command -v openssl >/dev/null 2>&1; then
    OPENSSL="$(command -v openssl)"
else
    die "openssl not found (it ships with macOS as /usr/bin/openssl)"
fi
[ -x "$OPENSSL" ] || die "openssl is not executable: $OPENSSL"

# ---- keychain helpers (read-only) --------------------------------------------------------------------------------
login_keychain() {
    local out
    out="$(security login-keychain 2>/dev/null | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | head -n 1)" || true
    [ -n "$out" ] || out="$HOME/Library/Keychains/login.keychain-db"
    printf '%s' "$out"
}

# "<SHA-1>\t<name>\t<note>" for every distinct code-signing identity (security find-identity without -v lists untrusted
# ones too; the output has two sections, so the same identity can appear twice: de-duplicated by hash).
list_signing_identities() {
    local out
    out="$(security find-identity -p codesigning 2>/dev/null)" || return 0
    printf '%s\n' "$out" \
        | sed -n 's/^[[:space:]]*[0-9]*) \([0-9A-Fa-f]\{40\}\) "\(.*\)"\(.*\)$/\1	\2	\3/p' \
        | awk -F'\t' '!seen[toupper($1)]++'
}

named_identities() {
    list_signing_identities | awk -F'\t' -v n="$IDENTITY_NAME" '$2 == n'
}

count_lines() { printf '%s' "$1" | grep -c . || true; }

# ---- certificate creation (openssl only, no keychain) -----------------------------------------------------------------
make_certificate() {  # $1 = directory; writes cert.pem, key.pem, identity.p12; sets CERT_SHA1 and P12_PASS
    local d="$1" fp
    cat > "$d/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days "$CERT_DAYS" -config "$d/cert.cnf" \
        -keyout "$d/key.pem" -out "$d/cert.pem" >/dev/null 2>&1 || die "openssl could not create the certificate ($OPENSSL req failed)"
    # The certificate must really carry the code-signing usage, or codesign will not accept it.
    "$OPENSSL" x509 -in "$d/cert.pem" -noout -text > "$d/cert.txt" 2>&1 || die "openssl cannot read the certificate it just made"
    grep -q "Code Signing" "$d/cert.txt" || die "the certificate lacks the Code Signing extended key usage (openssl config problem)"
    grep -q "Digital Signature" "$d/cert.txt" || die "the certificate lacks the Digital Signature key usage"
    grep -q "CA:FALSE" "$d/cert.txt" || die "the certificate is not a leaf (CA:FALSE missing)"
    fp="$("$OPENSSL" x509 -in "$d/cert.pem" -noout -fingerprint -sha1 | sed -e 's/^.*=//' -e 's/://g' | tr 'a-f' 'A-F')"
    printf '%s' "$fp" | grep -Eq '^[0-9A-F]{40}$' || die "could not read the certificate fingerprint"
    CERT_SHA1="$fp"
    # macOS 'security import' cannot read the new default PKCS#12 encryption of OpenSSL 3 (AES/PBKDF2), so the legacy
    # 3DES/SHA-1 flavour is requested explicitly; LibreSSL (/usr/bin/openssl) and OpenSSL 3 both accept these options.
    # A non-empty password is required: macOS rejects empty-password files from OpenSSL.
    P12_PASS="$("$OPENSSL" rand -hex 16)"
    MCAP_P12_PASS="$P12_PASS" "$OPENSSL" pkcs12 -export -inkey "$d/key.pem" -in "$d/cert.pem" -name "$IDENTITY_NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout env:MCAP_P12_PASS -out "$d/identity.p12" >/dev/null 2>&1 \
        || die "openssl could not write the PKCS#12 file"
    MCAP_P12_PASS="$P12_PASS" "$OPENSSL" pkcs12 -in "$d/identity.p12" -passin env:MCAP_P12_PASS -nokeys -noout >/dev/null 2>&1 \
        || die "the PKCS#12 file does not read back"
}

describe_certificate() {  # $1 = directory
    log "certificate: CN=$IDENTITY_NAME, RSA 2048, sha256, $CERT_DAYS days, key usage Digital Signature, extended key usage Code Signing, CA:FALSE"
    log "SHA-1 of the certificate: $CERT_SHA1   (openssl: $("$OPENSSL" version | head -n 1))"
}

# ---- self-test: sign a temporary copy of /usr/bin/true -----------------------------------------------------------------
SELFTEST_OUT=""
SELFTEST_DR=""
selftest() {  # sets SELFTEST_OUT / SELFTEST_DR; returns 0 when signing and verification worked
    local dir="$TMP_DIR/selftest" rc=0
    rm -rf "$dir"
    mkdir -p "$dir"
    cp /usr/bin/true "$dir/true"
    SELFTEST_DR=""
    SELFTEST_OUT="$(codesign --force --sign "$HASH" --timestamp=none --identifier "$BUNDLE_ID" "$dir/true" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    SELFTEST_OUT="$(codesign --verify --strict --verbose=2 "$dir/true" 2>&1)" || { SELFTEST_OUT="verify failed: $SELFTEST_OUT"; return 1; }
    SELFTEST_DR="$({ codesign -d -r- "$dir/true" 2>&1 | sed -n 's/^#* *designated => //p' | head -n 1; } || true)"
    [ -n "$SELFTEST_DR" ] || { SELFTEST_OUT="signed, but the designated requirement could not be read"; return 1; }
    return 0
}

classify_refusal() {  # stdin-less: uses SELFTEST_OUT; prints trust | access | other
    case "$SELFTEST_OUT" in
        *"no identity found"*|*"not trusted"*|*"NOT_TRUSTED"*|*"CSSMERR_TP_NOT_TRUSTED"*) echo trust ;;
        *errSecInternalComponent*|*"User interaction is not allowed"*|*"not allowed"*) echo access ;;
        *) echo other ;;
    esac
}

print_trust_hint() {
    cat <<EOF
[signing] codesign refused the identity, most likely because macOS does not trust a self-signed certificate by default.
[signing] This is the follow-up, only if you want it. Run this script again with --trust, or do it by hand:
[signing]     CERT="\$(mktemp "\${TMPDIR:-/tmp}/mcap-signing-cert.XXXXXX")"
[signing]     security find-certificate -c "$IDENTITY_NAME" -p > "\$CERT"
[signing]     security add-trusted-cert -r trustRoot -p codeSign "\$CERT"
[signing] What it does: macOS opens a password dialog ("You are making changes to your Certificate Trust Settings"). It records,
[signing] for YOUR user account only (not the whole Mac), that this one certificate is trusted for the Code Signing policy.
[signing] It changes nothing for other certificates, Gatekeeper or other apps. Undo: security remove-trusted-cert "\$CERT"
[signing] (or delete the identity, see --help). Alternative without the command line: Keychain Access > login > My Certificates >
[signing] double-click "$IDENTITY_NAME" > Trust > Code Signing: Always Trust.
EOF
}

print_access_hint() {
    cat <<EOF
[signing] codesign could not use the private key (not a trust problem, so --trust would not help). Usually the login keychain
[signing] is locked or this shell has no access to your desktop session (ssh, a terminal started before login). Run this script
[signing] again from Terminal.app in your desktop session; when macOS asks "codesign wants to sign using key ...", type your
[signing] login password into that dialog and choose Always Allow.
EOF
}

# ---- trust step (only with --trust, only after a refusal) --------------------------------------------------------------
do_trust() {
    local pem="$TMP_DIR/cert-for-trust.pem" fp
    if [ -f "$TMP_DIR/cert.pem" ] && [ "$CERT_SHA1" = "$HASH" ]; then
        cp "$TMP_DIR/cert.pem" "$pem"
    else
        security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" > "$pem" 2>/dev/null || die "cannot export the certificate '$IDENTITY_NAME' from $KEYCHAIN"
        fp="$("$OPENSSL" x509 -in "$pem" -noout -fingerprint -sha1 2>/dev/null | sed -e 's/^.*=//' -e 's/://g' | tr 'a-f' 'A-F')"
        [ "$fp" = "$HASH" ] || die "the certificate named '$IDENTITY_NAME' that the keychain returned (SHA-1 ${fp:-unknown}) is not the identity $HASH. Use Keychain Access to set the trust by hand."
    fi
    log "setting the user-domain trust for this one certificate: security add-trusted-cert -r trustRoot -p codeSign <cert.pem>"
    log "macOS now shows a password dialog (Certificate Trust Settings). Enter your login password THERE; this script does not see it."
    if ! security add-trusted-cert -r trustRoot -p codeSign "$pem"; then
        die "security add-trusted-cert failed or was cancelled (nothing was changed by this script). Alternative: Keychain Access > login > My Certificates > $IDENTITY_NAME > Trust > Code Signing: Always Trust"
    fi
    log "trust setting added for your user account (undo: security remove-trusted-cert <cert.pem>, or security delete-identity -t ...)"
}

print_removal() {
    echo "To remove the identity again (certificate, private key and its trust setting):"
    echo "    security delete-identity -c \"$IDENTITY_NAME\" -t \"$KEYCHAIN\""
    echo "  or Keychain Access > login > My Certificates > $IDENTITY_NAME > Delete. Then scripts/build_app.sh signs ad-hoc again."
}

# ============================================================ main ============================================================
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcap-signing.XXXXXX")"
chmod 700 "$TMP_DIR"

# ---- --export-only: no keychain at all --------------------------------------------------------------------------------
if [ -n "$EXPORT_DIR" ]; then
    [ ! -e "$EXPORT_DIR" ] || die "$EXPORT_DIR already exists (give a new directory name; it will hold a private key)"
    make_certificate "$TMP_DIR"
    mkdir -p "$EXPORT_DIR"
    chmod 700 "$EXPORT_DIR"
    cp "$TMP_DIR/identity.p12" "$EXPORT_DIR/$P12_FILE_NAME"
    cp "$TMP_DIR/cert.pem" "$EXPORT_DIR/$CERT_FILE_NAME"
    chmod 600 "$EXPORT_DIR/$P12_FILE_NAME"
    describe_certificate "$TMP_DIR"
    log "wrote $EXPORT_DIR/$P12_FILE_NAME and $EXPORT_DIR/$CERT_FILE_NAME (no keychain was touched)"
    echo "One-time password of the .p12 file (it is not stored anywhere else): $P12_PASS"
    echo "Import by hand: double-click the .p12 in Finder (Keychain Access, keychain: login), or"
    echo "    security import \"$EXPORT_DIR/$P12_FILE_NAME\" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign"
    echo "Delete the directory afterwards: rm -rf \"$EXPORT_DIR\""
    exit 0
fi

KEYCHAIN="$(login_keychain)"
log "login keychain: $KEYCHAIN"
[ "$DRY_RUN" != 1 ] || log "dry run: the keychain is only read; nothing is imported, signed or trusted"

MATCHES="$(named_identities)"
COUNT="$(count_lines "$MATCHES")"
if [ "$COUNT" -gt 1 ]; then
    echo "[signing] ERROR: $COUNT identities are named '$IDENTITY_NAME':" >&2
    printf '%s\n' "$MATCHES" | while IFS="$(printf '\t')" read -r h n note; do echo "    $h  $n  $note" >&2; done
    DIED=1
    echo "[signing] Keep one and delete the others in Keychain Access (or: security delete-identity -Z <SHA-1> -t), then run this again." >&2
    exit 1
fi

if [ "$COUNT" -eq 1 ]; then
    HASH="$(printf '%s' "$MATCHES" | cut -f1 | tr 'a-f' 'A-F')"
    NOTE="$(printf '%s' "$MATCHES" | cut -f3 | sed -e 's/^[[:space:]]*//')"
    log "the identity already exists (SHA-1 $HASH)${NOTE:+ $NOTE}: nothing is created or imported"
    CERT_SHA1="$HASH"
else
    log "no identity named '$IDENTITY_NAME' yet"
    make_certificate "$TMP_DIR"
    describe_certificate "$TMP_DIR"
    if [ "$DRY_RUN" = 1 ]; then
        log "(that certificate was generated only to prove openssl works here; it is deleted when this script ends)"
    fi
    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] security trade-off of a real run: the key lives in your login keychain and codesign may use it without a prompt (any process running as"
        echo "[dry-run]   you can sign with it); code signed with it inherits the permissions you grant $APP_NAME; the app has no hardened runtime."
        echo "[dry-run]   The ad-hoc alternative has none of that and costs a permission re-approval after every rebuild. Full text: header of this script."
        echo "[dry-run] would run: security import <identity.p12 made above> -k \"$KEYCHAIN\" -P <random one-time password> -T /usr/bin/codesign"
        echo "[dry-run]   (adds one certificate and one private key to the login keychain; macOS may ask to unlock it)"
        HASH=""          # the real run creates a new key pair, so the throw-away SHA-1 above is not shown below
    else
        log "importing into $KEYCHAIN (macOS may ask to unlock the keychain: answer in that dialog) ..."
        security import "$TMP_DIR/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign \
            || die "security import failed (nothing was added, or the keychain is locked/cancelled). Alternative: $0 --export-only <dir>, then import the .p12 by hand"
        MATCHES="$(named_identities)"
        HASH=""
        # the imported identity must be the certificate made above (and the only one with this name)
        while IFS="$(printf '\t')" read -r h n note; do
            [ -n "$h" ] || continue
            if [ "$(printf '%s' "$h" | tr 'a-f' 'A-F')" = "$CERT_SHA1" ]; then HASH="$CERT_SHA1"; fi
        done <<EOF
$MATCHES
EOF
        [ -n "$HASH" ] || die "the import finished but 'security find-identity -p codesigning' does not list the new identity (SHA-1 $CERT_SHA1). Look in Keychain Access (keychain: login)."
        log "imported: identity '$IDENTITY_NAME', SHA-1 $HASH"
    fi
fi

if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] would then self-test: copy /usr/bin/true to a temp dir; codesign --force --sign ${HASH:-<SHA-1 of the new certificate>} --timestamp=none --identifier $BUNDLE_ID <copy>;"
    echo "[dry-run]   codesign --verify --strict <copy>; codesign -d -r- <copy>   (prints the designated requirement)"
    if [ "$ALLOW_TRUST" = 1 ]; then
        echo "[dry-run] if codesign refused: security add-trusted-cert -r trustRoot -p codeSign <cert.pem>   (opens a macOS password dialog)"
    else
        echo "[dry-run] if codesign refuses, it prints the --trust follow-up (user-domain trust, needs --trust) and exits 3"
    fi
    echo
    print_removal
    log "dry run finished; the keychain was only read"
    exit 0
fi

# ---- self-test ---------------------------------------------------------------------------------------------------------
log "self-test: signing a temporary copy of /usr/bin/true with the identity"
log "if macOS asks 'codesign wants to sign using key ...': type your login password into THAT dialog and choose Always Allow"
if ! selftest; then
    KIND="$(classify_refusal)"
    echo "[signing] codesign output: $SELFTEST_OUT" >&2
    if [ "$KIND" = access ]; then
        print_access_hint >&2
        exit 3
    fi
    if [ "$ALLOW_TRUST" != 1 ]; then
        print_trust_hint >&2
        [ "$KIND" = trust ] || echo "[signing] (the message above is not the usual 'no identity found'; if --trust does not help, open an issue with that output, redacted)" >&2
        echo "[signing] The identity is in your keychain (SHA-1 $HASH). Run '$0 --trust' to apply the follow-up." >&2
        exit 3
    fi
    do_trust
    log "self-test again after setting the trust ..."
    if ! selftest; then
        echo "[signing] codesign output: $SELFTEST_OUT" >&2
        die "codesign still refuses the identity after the trust step. Nothing else will be changed. Send me the output above."
    fi
fi

log "self-test OK: signed and verified a temporary copy of /usr/bin/true"
echo
echo "Identity    : $IDENTITY_NAME"
echo "SHA-1       : $HASH"
echo "Keychain    : $KEYCHAIN"
echo "Designated requirement of what this identity signs (macOS stores exactly this for the app's permissions):"
echo "    $SELFTEST_DR"
echo
echo "Next:"
echo "  1. scripts/build_app.sh --install --require-identity     (or: scripts/install.sh --require-signing)"
echo "  2. grant the permissions once more (an ad-hoc build's permissions do not carry over to this identity):"
echo "       open -n -W -a ~/Applications/$APP_SHORT_NAME.app --stdout \"\$(tty)\" --stderr \"\$(tty)\" --args setup"
echo "     After that, rebuilds keep them. build_app.sh prints 'designated requirement unchanged' to confirm it."
echo
echo "Security note: anything signed with this identity inherits the permissions you grant the app, and any process running as you can"
echo "sign with the key (codesign may use it without a prompt); the app has no hardened runtime. Details: the header of this script, README."
echo
print_removal
exit 0
