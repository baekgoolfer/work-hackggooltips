#!/bin/bash
# The bundle identifier and the names of the app, in one place. Sourced by the scripts that build, sign, install, remove or package the app; not run on
# its own (the file keeps its name: the packaging helpers copy and read it by that name).
#
# The identifier (reverse-DNS, for example org.meetingcapture.app) is ONE build input. It is the CFBundleIdentifier in Info.plist, the codesign
# --identifier, the label of the LaunchAgent and the stem of the package identifier. macOS ties the Microphone, System Audio Recording and
# Notifications permissions to it, so a different identifier is a different app to macOS (docs/CONFIGURATION.md, "Identifiers").
#
#   mcap_valid_bundle_id VALUE        exit 0 when VALUE is a reverse-DNS identifier: dot-separated labels of letters, digits and hyphens, at least two
#                                     labels, no label starting or ending with a hyphen, at most 155 characters. Nothing else gets into a file name, a
#                                     sed expression, a plist or a launchctl command.
#   mcap_bundle_id_refusal VAR VALUE  the one-line refusal text (what an identifier must look like) for a script that refuses VALUE of VAR
#   mcap_app_bundle_id APP            the CFBundleIdentifier of APP/Contents/Info.plist; empty when the app or the key is missing
#   mcap_resolve_bundle_id [APP...]   the identifier to use: the first APP that has one (an installed or built app is the truth about itself), else the
#                                     environment variable MCAP_BUNDLE_ID, else MCAP_DEFAULT_BUNDLE_ID. Prints it; a bad MCAP_BUNDLE_ID prints the reason
#                                     to stderr and returns 1. A CFBundleIdentifier that is not valid (a damaged or foreign plist) is warned about and skipped.
#
# The two names are build inputs next to the id and are resolved the same way: an installed or built app tells its own names (CFBundleDisplayName and
# CFBundleName in Info.plist), else the environment, else the default. They are what the app shows people and what it is called on disk:
#   MCAP_APP_NAME        the human name (default "Catch Everything"): CFBundleDisplayName, the usage strings in Info.plist, every message and the disk image
#                        volume. ASCII letters, digits, spaces, hyphens and periods, starting with a letter or digit, no trailing space, 1 to 40 characters.
#   MCAP_APP_SHORT_NAME  the file-safe short name (default "CATE"): the app folder <short>.app, its executable, CFBundleName, the disk image and package file
#                        names. ASCII letters and digits, starting with a letter, 1 to 32 characters. It is a file name that scripts delete, so nothing else.
# An empty value counts as unset. The paths and identifiers that are NOT names of the product (the data folder MeetingCapture, the Keychain items, the
# python package mcap, the daemon label org.meetingcapture.asr) are not derived from these: changing them would orphan data that already exists.
#
#   mcap_valid_app_name VALUE / mcap_valid_app_short_name VALUE   exit 0 when VALUE is acceptable (the rules above); nothing else gets into a file name, a
#                                     sed expression, a plist or a command
#   mcap_app_name_refusal VAR VALUE / mcap_app_short_name_refusal VAR VALUE   the one-line refusal texts
#   mcap_app_display_name APP / mcap_app_short_name APP   CFBundleDisplayName / CFBundleName of APP/Contents/Info.plist; empty when missing
#   mcap_resolve_app_name [APP...] / mcap_resolve_app_short_name [APP...]   like mcap_resolve_bundle_id: the first APP that has a valid value, else
#                                     MCAP_APP_NAME / MCAP_APP_SHORT_NAME, else the default; a bad environment value prints the reason and returns 1
#   mcap_apps_with_bundle_id DIR ID   the *.app folders directly in DIR whose CFBundleIdentifier is ID, one path per line (two apps with one id would
#                                     share one login agent and one set of permissions)

set -euo pipefail

MCAP_DEFAULT_BUNDLE_ID="org.meetingcapture.app"
MCAP_DEFAULT_APP_NAME="Catch Everything"
MCAP_DEFAULT_APP_SHORT_NAME="CATE"

mcap_valid_bundle_id() {  # $1 = candidate
    local id="$1"
    [ "${#id}" -le 155 ] || return 1
    # characters first (tr in the C locale deletes the allowed ones; the # keeps a trailing newline from being lost in $(...)), then the shape
    [ "$(printf '%s#' "$id" | LC_ALL=C tr -d 'A-Za-z0-9.-')" = "#" ] || return 1
    case "$id" in
        *.*) ;;
        *) return 1 ;;                                  # one label, or empty
    esac
    case "$id" in
        .*|*.|*..*|-*|*-|*.-*|*-.*) return 1 ;;         # an empty label, or a label that starts or ends with a hyphen
    esac
    return 0
}

mcap_app_bundle_id() {  # $1 = app bundle
    plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# the refusal text, one wording for every script: $1 = where the value came from (a variable name), $2 = the value
mcap_bundle_id_refusal() {
    printf '%s=%q is not a valid bundle identifier: use reverse-DNS, dot-separated labels of letters, digits and hyphens, at least two labels, no label starting or ending with a hyphen, at most 155 characters (for example org.example.meetingcapture)' "$1" "$2"
}

mcap_resolve_bundle_id() {  # [app...]
    local app id
    for app in "$@"; do
        id="$(mcap_app_bundle_id "$app")"
        [ -n "$id" ] || continue
        if mcap_valid_bundle_id "$id"; then printf '%s\n' "$id"; return 0; fi
        echo "WARNING: the CFBundleIdentifier of $app is not a valid identifier ($(printf '%q' "$id")): ignored" >&2
    done
    id="${MCAP_BUNDLE_ID:-$MCAP_DEFAULT_BUNDLE_ID}"
    if ! mcap_valid_bundle_id "$id"; then
        echo "$(mcap_bundle_id_refusal MCAP_BUNDLE_ID "$id")" >&2
        return 1
    fi
    printf '%s\n' "$id"
}

# ---- the names -----------------------------------------------------------------------------------------------------
# characters first (tr in the C locale deletes the allowed ones; the # keeps a trailing newline from being lost in $(...)), then length and shape. The
# characters are all ASCII once they pass, so ${#n} counts characters and the case patterns below cannot match anything else.
mcap_valid_app_name() {  # $1 = candidate
    local n="$1"
    [ -n "$n" ] || return 1
    [ "$(printf '%s#' "$n" | LC_ALL=C tr -d 'A-Za-z0-9 .-')" = "#" ] || return 1
    [ "${#n}" -le 40 ] || return 1
    case "$n" in
        [A-Za-z0-9]*) ;;
        *) return 1 ;;                                  # a leading space, hyphen or period
    esac
    case "$n" in
        *" ") return 1 ;;
    esac
    return 0
}

mcap_valid_app_short_name() {  # $1 = candidate
    local n="$1"
    [ -n "$n" ] || return 1
    [ "$(printf '%s#' "$n" | LC_ALL=C tr -d 'A-Za-z0-9')" = "#" ] || return 1
    [ "${#n}" -le 32 ] || return 1
    case "$n" in
        [A-Za-z]*) return 0 ;;
    esac
    return 1                                            # starts with a digit
}

mcap_app_name_refusal() {  # $1 = where the value came from (a variable name), $2 = the value
    printf '%s=%q is not a valid app name: use ASCII letters, digits, spaces, hyphens and periods, starting with a letter or digit, no trailing space, 1 to 40 characters (for example "Example Recorder")' "$1" "$2"
}

mcap_app_short_name_refusal() {  # $1 = where the value came from (a variable name), $2 = the value
    printf '%s=%q is not a valid short app name: use ASCII letters and digits only, starting with a letter, 1 to 32 characters; it is the file name of the app and of its program (for example ExampleRecorder)' "$1" "$2"
}

mcap_app_display_name() {  # $1 = app bundle
    plutil -extract CFBundleDisplayName raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

mcap_app_short_name() {  # $1 = app bundle
    plutil -extract CFBundleName raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

mcap_resolve_app_name() {  # [app...]
    local app n
    for app in "$@"; do
        n="$(mcap_app_display_name "$app")"
        [ -n "$n" ] || continue
        if mcap_valid_app_name "$n"; then printf '%s\n' "$n"; return 0; fi
        echo "WARNING: the CFBundleDisplayName of $app is not a valid app name ($(printf '%q' "$n")): ignored" >&2
    done
    n="${MCAP_APP_NAME:-$MCAP_DEFAULT_APP_NAME}"
    if ! mcap_valid_app_name "$n"; then
        echo "$(mcap_app_name_refusal MCAP_APP_NAME "$n")" >&2
        return 1
    fi
    printf '%s\n' "$n"
}

mcap_resolve_app_short_name() {  # [app...]
    local app n
    for app in "$@"; do
        n="$(mcap_app_short_name "$app")"
        [ -n "$n" ] || continue
        if mcap_valid_app_short_name "$n"; then printf '%s\n' "$n"; return 0; fi
        echo "WARNING: the CFBundleName of $app is not a valid short app name ($(printf '%q' "$n")): ignored" >&2
    done
    n="${MCAP_APP_SHORT_NAME:-$MCAP_DEFAULT_APP_SHORT_NAME}"
    if ! mcap_valid_app_short_name "$n"; then
        echo "$(mcap_app_short_name_refusal MCAP_APP_SHORT_NAME "$n")" >&2
        return 1
    fi
    printf '%s\n' "$n"
}

mcap_apps_with_bundle_id() {  # $1 = folder, $2 = bundle id
    local app
    for app in "$1"/*.app; do
        [ -d "$app" ] || continue
        [ "$(mcap_app_bundle_id "$app")" = "$2" ] || continue
        printf '%s\n' "$app"
    done
}
