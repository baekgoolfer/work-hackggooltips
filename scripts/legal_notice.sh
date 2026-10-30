#!/bin/bash
# The recording legal notice. Sourced by scripts/install.sh and by the confirm step of scripts/make_launchagent.sh; not run on its own.
#
#   legal_notice_gate <script-name> <accepted: 0|1> <dry-run: 0|1> [app name]
#
#   The app name is the human name the caller resolved (scripts/bundle_id.sh: mcap_resolve_app_name); without it the notice says "This app".
#
#   - prints the notice (always, a dry run included, so it can be read before anything happens);
#   - dry run: stops there, nothing is asked;
#   - accepted=1 (the --accept-legal-notice option): the notice counts as accepted without a question;
#   - on a terminal: asks you to type yes (the whole word, once per run);
#   - without a terminal and without the option: refuses (return 1), because a script that runs unattended must not accept this
#     for you by accident.
# The caller turns return 1 into its own error, before it has changed anything.

set -euo pipefail

legal_notice_text() {  # $1 = the name of the app
    printf 'LEGAL NOTICE: %s records other people.\n' "${1:-This app}"
    cat <<'EOF'

It records the audio your Mac plays (every other participant of a call) and your microphone, also while you are muted in the
meeting app. It shows nothing to the other participants and does not use the recording function of Zoom, Teams or Meet, so those
apps show no "recording" banner either.

In many countries, states and organisations it is illegal or against policy to record a conversation without telling the people in
it or getting their consent (one-party or all-party consent, workplace and data-protection law such as the GDPR, rules for health
and other sensitive data, the terms of the meeting platform and of your employer). Recordings, transcripts and notes of identifiable
people are personal data.

You alone are responsible for knowing and following the rules that apply to every meeting you record, for telling the participants
and getting consent where it is required, for storing, sharing and deleting the files lawfully, and for not using this tool to
record covertly. Unless a meeting is Local-Only, its transcript text, title and your vocabulary list (and calendar details if you
enabled them) are sent to Anthropic's Claude; the audio is not. Do not use the tool for meetings with regulated or confidential
content unless your agreements and policies allow it.

This is general information, not legal advice. The software comes without warranty (Apache License 2.0). The full text is in
README.md ("Legal notice") and docs/PRIVACY_AND_CONSENT.md.
EOF
}

legal_notice_gate() {
    local who="$1" accepted="$2" dry="$3" app="${4:-}" answer=""
    echo
    legal_notice_text "$app" | sed "s/^/[$who] /"
    echo
    if [ "$dry" = 1 ]; then
        echo "[$who] dry run: a real run asks you to type yes here (without a terminal it needs the option --accept-legal-notice)"
        return 0
    fi
    if [ "$accepted" = 1 ]; then
        echo "[$who] legal notice: accepted with --accept-legal-notice"
        return 0
    fi
    if [ ! -t 0 ]; then
        echo "[$who] ERROR: this run has no terminal to ask on. Read the notice above and, if you accept it, run again with --accept-legal-notice." >&2
        return 1
    fi
    printf "Type yes to confirm that you have read this notice and will follow the rules that apply to your meetings: "
    read -r answer || answer=""
    if [ "$answer" != "yes" ]; then
        echo "[$who] ERROR: the notice was not accepted." >&2
        return 1
    fi
    return 0
}
