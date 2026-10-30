# Catch Everything (CATE)

Catch Everything (short name: CATE) is a macOS menu-bar app that notices when you join a call (Zoom and Teams, other call apps such as Slack huddles, Webex, Discord or FaceTime, and Google Meet if you turn it on), records your microphone and the call audio on your Mac, transcribes it locally with Whisper, writes meeting notes with Claude, and files the result in a folder you choose. There is no record button: join a call and it starts, leave and it stops.

[한국어 README](README.ko.md) | [Install guide](docs/INSTALL.md) | [Privacy and consent](docs/PRIVACY_AND_CONSENT.md) | [Contributing](CONTRIBUTING.md) | [Security](SECURITY.md)

> **Status: experimental (0.2.0).** It was built and used by one person on one Apple silicon Mac running macOS 26. Only Zoom detection was verified in real calls, on that setup only. Teams, Google Meet, the other call apps, other macOS versions and other audio setups are not verified in real calls. There is no support commitment. See [Limitations](#limitations).

> **Names.** The product is Catch Everything; CATE is its short name and the file name of the app (`CATE.app`). The data folder, the log folder and the Keychain items keep the internal name MeetingCapture (`~/Library/Application Support/MeetingCapture`, `~/Library/Logs/MeetingCapture`, Keychain services such as "MeetingCapture Anthropic API key"): they are paths and identifiers, not the name of the product, and renaming them would orphan data that already exists. A copy that was built with other names (`MCAP_APP_NAME`, `MCAP_APP_SHORT_NAME`, see [Names and identifier of the app](docs/CONFIGURATION.md#names-and-identifier-of-the-app)) has another app file name: use that name where the commands below say `CATE.app`.

## Legal notice: this tool records other people

Catch Everything records the audio your Mac plays (every other participant in a call) and your microphone. **The microphone is recorded even while you are muted in the meeting app.** The app plays no sound and shows nothing to other participants, and it does not use the recording function of Zoom, Teams or Meet, so those apps show no "recording" banner either.

In many countries, states and organisations it is illegal or against policy to record a conversation without telling the people in it or getting their consent. Rules differ: one-party versus all-party consent, workplace and privacy law, data-protection law such as the GDPR, rules for health and other sensitive data, and the terms of the meeting platform and of your employer. Recordings, transcripts and notes of identifiable people are personal data.

You alone are responsible for knowing and following the rules that apply to every meeting you record; for telling participants and getting consent where it is required; for keeping, sharing and deleting the files lawfully; and for not using the tool for covert recording. Do not use it for meetings with regulated or confidential content (health data, client secrets) unless your agreements and policies allow it: transcript text, the meeting title, your vocabulary list and (if enabled) calendar details are sent to Anthropic's Claude, and optional speech engines can send audio to other servers ([what leaves your Mac](docs/PRIVACY_AND_CONSENT.md)).

This notice is general information, not legal advice. Ask a lawyer. The software is provided as is, without warranty, and the authors accept no liability (Apache License 2.0, sections 7 and 8).

## What it does

```
A call is detected (Zoom, Teams, another call app, Meet if enabled)
  -> two tracks are recorded: the system audio ("Remote") and your microphone (labelled with SELF_NAME, default "Me")
  -> after the call, on your Mac: echo cancellation of the mic track, voice activity detection,
     speech recognition with a local Whisper model (mlx-whisper large-v3), hallucination filter -> transcript.md
  -> optional passes with Claude (your own account or API key): term cleanup, meeting note, fact check of the note
  -> the finished folder is moved to ARCHIVE_DIR/YYYY-MM/YYYY-MM-DD_HHMM_<title>/
```

The meeting folder holds `transcript.md` (the raw transcript, never edited by an LLM), `transcript.cleaned.md`, `meeting-note.md`, the audio as `.m4a` files (a mix and one per track), `session.json` and `transcript.json`. Failures never delete audio or transcript: if the note step fails, the transcript stays and you can run it again.

Speech recognition stays on your Mac in the default setup. Audio is never sent to Claude.

## Requirements

- An Apple silicon Mac (M1 or newer) on macOS 14.4 or later, with **16 GB of RAM or more recommended**: the speech model takes about 4 GB while a meeting is transcribed, next to the call and everything else you run. Intel Macs are not supported (the speech model needs Apple silicon).
- The Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not needed: the app is built with `swiftc`.
- **Python 3.12 or 3.13** is required (3.13 is what the pinned packages were verified with; the pinned numpy and scipy do not install on 3.11 or older, and the `python3` that comes with macOS or the Command Line Tools is not a substitute: install 3.12 or 3.13 yourself). `scripts/setup_python.sh` looks for `python3.13`, then `python3.12`, in Homebrew, the python.org framework, `/usr/local/bin` and on your `PATH`; point it at another interpreter with `MCAP_PYTHON=/path/to/python3.13`. The scripts never install Python or Homebrew packages for you.
- **Your own Claude access** for the notes: an Anthropic API key (the supported path and the default, `CLAUDE_AUTH=api`) or, as an opt-in, a logged-in Claude subscription, plus the `claude` command-line tool (Claude Code) installed by you. Without it you still get audio and transcripts: on a personal install `setup` reports a missing or logged-out `claude` as a warning, not a failure, so automatic start is not blocked. Set `LOCAL_ONLY_DEFAULT=1` in `config.env` if you want transcripts only (otherwise every meeting tries the note step and keeps its transcript when that step fails). See [Anthropic and Claude](#anthropic-and-claude).
- Disk: about 0.55 GB for the Python environment, 3.08 GB for the speech model, about 0.7 GB of temporary audio per hour of meeting (deleted after publishing). Recording stops when free space drops below `MIN_FREE_DISK_GB`.
- Optional: Google Drive for desktop. The archive folder can be any folder; Drive is only one choice. Google Chrome is only needed if you turn on Google Meet detection or the browser meeting pages (`CALL_BROWSER_URLS`).

## Quick start

Plan for about 10 minutes of your own time plus the downloads (about 3.6 GB). Read the [legal notice](#legal-notice-this-tool-records-other-people) first.

```bash
# 1. Get the source (the clone address is the HTTPS address shown on this repository's page) and look at the install plan
#    (nothing is changed by --dry-run)
git clone <repository-url> meeting-capture
cd meeting-capture
make install ARGS="--dry-run --python --with-silero --pre-download-model"

# 2. Install: builds and signs the app (ad-hoc), copies the settings, creates the Python environment, downloads the models.
#    It shows the recording legal notice first and asks you to type yes. Without a terminal (CI, ssh without a tty) add
#    --accept-legal-notice to ARGS to accept it explicitly.
make install ARGS="--python --with-silero --pre-download-model"
```

The clone is part of the install: the app runs `pipeline/` from it, and `config.env` records its location as `PROJECT_DIR`. If you move the folder later, update `PROJECT_DIR` and run `make install` again.

```bash
# 3. Edit your settings (a copy of config/config.env.example). Review ARCHIVE_DIR and SELF_NAME. CLAUDE_AUTH=api is the default
#    (subscription is opt-in, see "Anthropic and Claude"); CALENDAR_LOOKUP=0 means never look at your calendar (the example's value)
open -e ~/Library/Application\ Support/MeetingCapture/config.env

# 4a. CLAUDE_AUTH=api (the default): store your Anthropic API key once; the macOS security tool asks for it, nothing else sees it
make set-api-key
#     check it with one tiny call (about a tenth of a cent)
cd pipeline && "$HOME/Library/Application Support/MeetingCapture/venv/bin/python" -m mcap api-key check && cd ..
# 4b. Only if you opted in to CLAUDE_AUTH=subscription: log in with the claude tool instead
claude auth login

# 5. Grant the permissions to CATE.app itself (the -n is required)
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args setup

# 6. Device test, about 15 seconds: records both tracks for real and prints the levels.
#    It plays a short sound; do not run it during a real meeting.
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out "$HOME/mcap-selftest"

# 7. Check configuration, models, Claude login or key, archive folder
make doctor
```

Then start the app by hand (`open ~/Applications/CATE.app`), start a Zoom meeting alone ("New Meeting"), speak for a minute, leave, and wait for the "meeting note is ready" notification. Do the same with Teams ("Meet now"). The step-by-step checklist with the expected results is [docs/LIVE_TEST.en.md](docs/LIVE_TEST.en.md) (English; the minimum before automatic start). The longer [docs/LIVE_TEST.md](docs/LIVE_TEST.md) is written in Korean.

Only when that works, turn on automatic start at login. This is deliberately gated, because from then on **every call you join is recorded**:

```bash
make confirm-live-tested                 # shows the legal notice again; you type yes and then 'confirmed'; it will not run without a terminal
scripts/make_launchagent.sh --load       # refused until the line above was done
```

Building, permissions, the optional fixed signing identity, upgrading and uninstalling are covered in [docs/INSTALL.md](docs/INSTALL.md). The scripts that change your system (`scripts/install.sh`, `scripts/uninstall.sh`, `scripts/setup_python.sh`, `scripts/make_launchagent.sh`, `scripts/make_signing_identity.sh`) accept `--dry-run` and are safe to run again; `make hash-lock` only prints a plan unless you add `--apply`.

### Install from a disk image (for people without a developer setup)

If you build the app yourself and want to hand a copy to somebody who has no developer tools, `make dmg` makes ONE file, `CATE-<version>.dmg` (the volume is named "Catch Everything"): it contains `CATE.app`, with its pipeline, the install helper and a Python runtime inside. The person who gets it drags `CATE.app` to Applications and opens it. The app is signed with its builder's own self-signed identity and is not notarized, so macOS shows a warning once (Control-click > Open, or System Settings > Privacy & Security > Open Anyway); at the first launch the app offers a guided installer in Terminal (about 4 GB of downloads). Nothing here uploads the file anywhere, and this repository does not claim that a download exists. If you got such a file from somebody, read the user guide first: [docs/USER_GUIDE.md](docs/USER_GUIDE.md) (Korean: [docs/USER_GUIDE.ko.md](docs/USER_GUIDE.ko.md)). How to build, share and test it: [docs/DISTRIBUTE.md](docs/DISTRIBUTE.md). The app records the other people in your calls: tell them first (see the legal notice above). Only Zoom has been verified in real calls, and this installer has not been run on a clean Mac yet.

## How detection works

The menu-bar app polls every 2 seconds and uses only public macOS interfaces; it does not read or modify the meeting apps, and it needs no account or plug-in for any of them.

- **Zoom:** a call is assumed when the Zoom process holds open network sockets (read with libproc, no extra permission) or is using the microphone. Zoom opens a few sockets for a few seconds when it is idle, which looks like a call for a moment, so weak evidence must last about 15 seconds before it counts.
- **Teams:** a call is assumed when Teams is using the microphone. Playing sound alone never counts.
- **Google Meet (off by default):** the address and title of Chrome tabs are read through Apple Events. This needs the broad Chrome "Automation" permission and is the least verified platform. Turn it on with `ENABLED_PLATFORMS=zoom,teams,meet`.
- **Calls of other apps (the named apps are on by default, never Google Meet):** a built-in table of call apps (Slack huddles, Cisco Webex, Discord, FaceTime, Skype, GoTo, Amazon Chime, BlueJeans, Lark, KakaoTalk, WhatsApp, JANDI) counts as a call when the app, or one of its helper processes, holds the microphone **and** plays sound; more apps go into `EXTRA_MEETING_APPS`. The table includes personal messengers (Discord, FaceTime, KakaoTalk, WhatsApp, Skype): their calls are recorded like any other call unless you switch the app off, in the **Call Apps** submenu (it lists every app of the table before its first call) or with `CALL_DETECT=off`. **Guessing is opt-in:** with `CALL_DETECT=generic` any other GUI app that is not on a built-in deny list (browsers, media players, recorders, dictation tools, Apple's own apps, ...) and that you have not denied counts too, after it has held the microphone and played sound for 45 seconds (`CALL_GENERIC_SECONDS`); such a recording posts a notification that names the app ("`<App>` looks like a call: recording started. Not a call? Menu > Never record `<App>`"). The **Never record** item (shown while any call of another app is recorded) and the **Call Apps** submenu change your decision, which is kept in `call-apps.json` (app ids, names and the decision only); while that file cannot be read, no call of another app is recorded. `ENABLED_PLATFORMS` lists only Zoom, Teams and Meet: it does not limit these calls, `CALL_DETECT` does (`CALL_DETECT=off` switches all of it off). A running Slack huddle or other call never blocks a Zoom, Teams or Meet meeting: that meeting takes the recording over. Meeting pages of Whereby, Jitsi, Webex web, Teams web and the Zoom web client are read from Chrome tab addresses only with `CALL_BROWSER_URLS=on` (the same Chrome Automation permission as Meet, so it is off by default and nobody who uses native apps is asked for it). An organisation policy can set these keys; on a Mac with a policy an unset `CALL_DETECT` means `off`.
- **What is verified:** only Zoom has been verified in real calls. Teams, Google Meet and every other app above are implemented from public signals and covered by unit tests with fakes, not by real calls: expect missed calls and the occasional recording of something that is not a call. [docs/DETECTION.md](docs/DETECTION.md) section 3b has the table of every platform with its signal, evidence tier and status.
- Recording starts after the signal has lasted 4 seconds and ends after a grace period of at least 30 seconds for Zoom, Teams and the calls of other apps. Audio the app itself plays is ignored.
- The system audio is captured with a Core Audio process tap (macOS 14.4 or later, the "System Audio Recording" permission) and the microphone with Core Audio: 48 kHz mono, no video, no screen capture.

To watch the signals yourself: `open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args probe --watch`. The formulas, thresholds and verification status are in [docs/DETECTION.md](docs/DETECTION.md). A false recording is possible (for example a Zoom microphone test): a recording with less than 20 seconds of speech is discarded, and an automatic recording that is digital silence on both tracks for `NO_SPEECH_STOP_MINUTES` stops itself.

## Privacy model

Short version. The full detail is in [docs/PRIVACY_AND_CONSENT.md](docs/PRIVACY_AND_CONSENT.md) and [docs/PRIVACY_LANES.md](docs/PRIVACY_LANES.md).

| What | Goes to | When |
|---|---|---|
| Transcript text, vocabulary list, title hint, calendar attendees (if the lookup is on) | Anthropic, through the `claude` tool | every meeting that is not local-only |
| Calendar lookup (event title, attendees) | your claude.ai login's Google Calendar connector | `CALENDAR_LOOKUP=auto` does it whenever your claude.ai login has the connector; `CALENDAR_LOOKUP=0` never does. The example `config.env` ships `0`; check the value in yours |
| The whole meeting folder, **including the audio of both sides** | the archive folder; if that is a cloud-sync folder such as Google Drive, to that provider and everyone with access to it | every meeting that is not local-only |
| Speech audio (and, for CLOVA, the terms of your vocabulary list; the API key you stored goes to that engine's host) | nowhere else by default. An external speech engine (NAVER CLOVA Speech, an OpenAI-style server you name, Azure, a company server) is an opt-in and needs a typed consent | only if configured |
| Calendar autostart (the event list around now: titles, times, attendee counts) | Google only (read-only Google Calendar API through your own OAuth client; the token stays in the Keychain). Nothing is sent to Anthropic or anyone else by this step | only with `OFFLINE_AUTOSTART=auto`, off by default. See [docs/CALENDAR_AUTOSTART.md](docs/CALENDAR_AUTOSTART.md) |
| Packages and models | PyPI, Hugging Face, GitHub (one-time downloads at install) | install |

**Local-only switch.** A local-only meeting is transcribed on your Mac and skips every lane that can leave it: external speech engines, Claude (cleanup, note, verification), the calendar lookup and the archive-folder upload. It is kept under `LOCAL_ARCHIVE_DIR` (default: a `local-meetings` folder in the app's support directory) and has a transcript but no note. Turn it on for one meeting with the **Local-Only Meeting** item in the menu (while the meeting is recorded, or afterwards until it is published), or for every new recording with `LOCAL_ONLY_DEFAULT=1` in `config.env`.

**Calendar autostart (opt-in, single user).** With `OFFLINE_AUTOSTART=auto` the app starts a recording by itself for an in-person conversation that is in your Google Calendar, using a read-only Google Calendar sign-in that you set up once in your own Google Cloud project (`python -m mcap gcal auth`; the token lives only in the Keychain, requests go only to Google). **It records whoever is in the room, without a button press.** Recording people can need their consent and can be illegal where you are; read [docs/CALENDAR_AUTOSTART.md](docs/CALENDAR_AUTOSTART.md) (warning, setup, what is read and sent, how to revoke) before you turn it on. The default install does not have it and the other people who use this project do not need it.

**Cloud speech engines (opt-in).** Two cloud engines are built in and **off** until you name them in `ASR_ENGINE`, store the API key in the Keychain (`mcap asr-engines secret set clova`) and type a consent (`mcap asr-engines consent clova`): `clova` (NAVER CLOVA Speech, with the invoke URL of your own domain) and `openai-compat` (any server that implements an OpenAI-style `/audio/transcriptions`; **you** choose the vendor behind it, and the consent names its host). They receive blocks of speech of up to `ASR_CLOUD_BLOCK_SECONDS` (the pauses cut out, 16 kHz mono WAV, with the remote participants' voices), the API key you stored for that host and, for the OpenAI-style server, the model name; CLOVA also receives the terms of your vocabulary list (not the aliases) as `boostings` while `ASR_SEND_VOCAB` is on and the policy allows it, and the OpenAI-style server receives no vocabulary. Never a title, a session id or the attendees, and never anything from a local-only meeting. The vendor bills you directly and this project does not price or budget it (it logs the audio seconds of every request and keeps the daily cap `ASR_CLOUD_DAILY_MINUTES`). The answer shape of CLOVA's sync call is not covered by its public documentation, so the first real call confirms it. CLOVA Speech is a product of NAVER Cloud and the project is not affiliated with it. See [docs/CONFIGURATION.md](docs/CONFIGURATION.md#cloud-providers-clova-and-openai-compatible) and, to add a vendor, [docs/ADD_A_PROVIDER.md](docs/ADD_A_PROVIDER.md).

Other things to know. Local logs contain meeting titles and short transcript snippets unless you set `LOG_CONTENT=0`; do that before attaching logs anywhere. `AUDIO_RETENTION_DAYS=N` deletes archived audio after N days. `mcap forget <folder>` deletes one meeting for good. `mcap doctor --share` prints a check report with your home folder and e-mail addresses removed.

## Configuration

Settings live in `~/Library/Application Support/MeetingCapture/config.env` (`KEY=VALUE`, installed from [config/config.env.example](config/config.env.example)). **The example file is the reference**: every key, its default and its meaning, with English and Korean comments. The pipeline reads the file on every run; the app reads it at start, so quit and reopen the app after changing detection or recording keys.

**Settings window.** The menu-bar item **Settings…** (Cmd-,) edits twenty of these keys in five tabs (General, Claude, Transcription, Detection, Privacy), stores the API keys in the macOS Keychain (never in `config.env`), shows what leaves the Mac under the saved settings, and offers **Restart now** after a save. It changes only the lines you touch, keeps your comments, writes a backup first and refuses values the parsers would misread. The consent to a cloud speech engine and the Google sign-in remain Terminal commands (the window opens Terminal for you). Details and what is not verified: [docs/SETTINGS.md](docs/SETTINGS.md). Editing the file by hand keeps working.

| Key | What it controls |
|---|---|
| `ARCHIVE_DIR` | where finished meetings go (default `~/Meetings`; a Google Drive folder works) |
| `SELF_NAME` | the label of your microphone track in transcripts (the other track is always `Remote`) |
| `UI_LANGUAGE` | language of the app's own texts (notifications, menu hints, dialogs): `en` (default) or `ko` |
| `ENABLED_PLATFORMS` | which of Zoom, Teams and Google Meet start recordings: `zoom,teams` by default, add `meet` to enable Google Meet. It does not limit the calls of other apps (`CALL_DETECT` does); an empty value switches all automatic detection off |
| `CALL_DETECT` | calls of other apps: `known` (the default: the table of call apps and `EXTRA_MEETING_APPS`, no guessing), `generic` (opt in: also any GUI app that holds the microphone and plays sound for `CALL_GENERIC_SECONDS`, 45 by default) or `off`; `EXTRA_MEETING_APPS` adds bundle ids (`id` or `id=Name`, comma separated); `CALL_BROWSER_URLS=on` adds meeting pages in Chrome. On a Mac with an organisation policy an unset value means `off` |
| `CALL_GENERIC_SECONDS` | `generic` only: how long an app must hold the microphone and play sound before it counts (default `45`) |
| `EXTRA_MEETING_APPS` | bundle ids of more call apps, comma separated, each `id` or `id=Name` (default none) |
| `CALL_BROWSER_URLS` | `on` also reads Chrome tab addresses for Whereby, Jitsi, Webex web, Teams web and the Zoom web client (default `off`; needs the Chrome Automation permission like Meet) |
| `CLAUDE_AUTH` | `api` (the default: Anthropic API key from the Keychain, billed per token) or `subscription` (opt-in: your Claude login) |
| `CALENDAR_LOOKUP` | read the matching calendar event for the title and attendees; `0` (the example file's value) turns it off, `auto` turns it on |
| `LOCAL_ONLY_DEFAULT` | `1` makes every new recording local-only |
| `AUDIO_RETENTION_DAYS` | delete archived audio older than N days (`0` keeps it) |
| `LOG_CONTENT` | `0` keeps meeting titles and transcript snippets out of the logs |
| `SYSTEM_AUDIO_MODE` | `global` records everything the Mac plays (music and alerts included), `app` only the meeting app |
| `ASR_LANGUAGES` | languages the speech recognition keeps, default `ko,en`; add more, for example `ko,en,ja` |
| `ASR_STRATEGY` | `dual` (the default: every chunk decoded with and without your vocabulary prompt, then merged by fixed rules; about 1.5 to 1.8 times the transcription time, local Whisper only) or `single` (one decode per chunk, faster) |
| `ASR_ENGINE` | `whisper` (the default, local), `clova`, `openai-compat`, `azure`, `remote` or `auto`; an external engine also needs the Keychain key (where it has one) and a typed consent |
| `ASR_CLOVA_INVOKE_URL` | the invoke URL of your CLOVA Speech domain (https, a NAVER Cloud gateway); empty = not configured |
| `ASR_OPENAI_COMPAT_URL` | base URL of an OpenAI-style transcription server (https, a DNS name); `ASR_OPENAI_COMPAT_MODEL` is the model name (default `whisper-1`) |
| `ASR_CLOUD_BLOCK_SECONDS` | seconds of speech per upload of a cloud engine, 30 to 1800, default `900` (`openai-compat` at most 720) |
| `NOTE_LANGUAGE` | `auto` (the meeting's main language), `ko` or `en` |
| `MAX_CLAUDE_CALLS_PER_MEETING` | hard cap of Claude calls for one meeting |
| `OFFLINE_AUTOSTART` | `off` (the default) or `auto`: the app starts a recording by itself for an in-person conversation in your Google Calendar. **It records whoever is in the room**: read [docs/CALENDAR_AUTOSTART.md](docs/CALENDAR_AUTOSTART.md) first. A single-user feature, needs your own Google Cloud OAuth client and `python -m mcap gcal auth` |
| `OFFLINE_START_BEFORE_MINUTES` | `OFFLINE_AUTOSTART=auto`: start up to this many minutes before the event starts (default `2`) |
| `OFFLINE_START_AFTER_MINUTES` | ... and up to this many minutes after it started (default `15`) |
| `OFFLINE_STOP_AFTER_END_MINUTES` | stop a recording that this feature started this many minutes after the event's end (default `10`) |
| `OFFLINE_IDLE_MAX_MINUTES` | no keyboard or mouse input for longer than this means nobody is at the Mac: no start (default `5`) |
| `OFFLINE_REQUIRE_GUESTS` | `1` (the default): the event needs at least one attendee besides you |
| `OFFLINE_MIN_MINUTES` | events shorter than this are never recorded (default `10`) |
| `OFFLINE_MAX_MINUTES` | events longer than this are never recorded (default `240`) |

Your own vocabulary (product names, people, jargon that Whisper mishears) goes into `~/Library/Application Support/MeetingCapture/vocabulary.txt`: one term per line, higher lines have priority, and `Acme = Akmee | Ackme` maps frequent mis-spellings to the right term. The seed is `config/vocabulary.txt`. After editing, `mcap reprocess --last --from asr` applies it to an existing meeting (see [Troubleshooting](#troubleshooting) for how to run `mcap`).

## Anthropic and Claude

The note-writing step runs the `claude` command-line tool (Claude Code) that you install yourself, as published by Anthropic and unmodified, with your own Anthropic API key (`CLAUDE_AUTH=api`, the default and the supported path) or, as an opt-in, with your own Claude login (`CLAUDE_AUTH=subscription`). Install it from [Anthropic's Claude Code documentation](https://code.claude.com/docs/en/overview). The app expects it at `~/.local/bin/claude` by default; `CLAUDE_BIN` in `config.env` changes that, and `command -v claude` shows where yours is.

- **api mode (the default):** the key is stored only in the macOS Keychain (`make set-api-key`), read just before each call and handed to the `claude` process through its environment, never through a command line, file or log. Every call costs money, and a bug or a false recording costs money too. Create a key just for this project and set a **monthly spend limit** for it in the Anthropic Console: that is the real safety net. `CLAUDE_DAILY_BUDGET_USD` and `CLAUDE_MEETING_BUDGET_USD` (5 and 2 USD by default, small on purpose) are additional brakes, and `mcap usage` shows what the last 7 and 30 days cost.
- **subscription mode (opt-in):** no key is used. **Check Anthropic's terms for your account before you choose it.** Anthropic's published rules limit a subscription login to ordinary individual use of Claude Code, and this tool runs `claude -p` in the background without you at the keyboard, so for unattended use or for an organisation use an API key. Whether your use is covered is for you to check. `NOTE_STOP_ON_OVERAGE=1` (the default, subscription mode only) stops the note step while Claude reports extra-usage billing and keeps the transcript (`mcap reprocess --allow-overage` forces a note).
- A meeting needs up to roughly 28 Claude calls at the default settings (cleanup batches, note, verification, optional calendar lookup); `MAX_CLAUDE_CALLS_PER_MEETING` caps it.
- This project does not include, modify, resell or proxy Claude Code, does not read, store or forward your Claude login tokens, and must not be used to share one account between people. Your use is subject to Anthropic's terms for your account type, its Usage Policy and, for health data, a business associate agreement if you need one. Transcript text, the meeting title, your vocabulary list and (if enabled) calendar details are sent to Anthropic; audio is not.

## Troubleshooting

Run `mcap` commands from the repository's `pipeline` folder with the app's Python environment:

```bash
cd pipeline
PY="$HOME/Library/Application Support/MeetingCapture/venv/bin/python"
"$PY" -m mcap doctor                      # same report as make doctor
"$PY" -m mcap reprocess --last            # resume or redo the last meeting from the stage that stopped
"$PY" -m mcap reprocess --last --from asr # transcribe again (after editing vocabulary.txt), then the note
"$PY" -m mcap reprocess --pending         # retry every failure that a retry can finish
```

- **Nothing is recorded.** Is the menu-bar icon there? Start the app (`open ~/Applications/CATE.app`) or, if you turned on login start, `scripts/make_launchagent.sh --load`. Is the platform in `ENABLED_PLATFORMS`? (Google Meet is off by default.) Watch the signals with `probe --watch` (see above). **Start Recording Now** in the menu records by hand.
- **The other side is silent** (the app notifies that the remote track is silent): the System Audio Recording permission is missing, which fails without an error. Check System Settings > Privacy & Security > Screen & System Audio Recording (the exact pane name differs between macOS versions), then run step 5 of the quick start again.
- **Permissions are stuck.** Quit the app, then run `tccutil reset All "$(defaults read ~/Applications/CATE.app/Contents/Info CFBundleIdentifier)"` and the `setup` step again. An ad-hoc signed build asks again after every rebuild; the optional fixed signing identity in [docs/INSTALL.md](docs/INSTALL.md) avoids that.
- **The archive folder is not there** (for example Google Drive is not running): the meeting waits in the staging folder and the menu shows `archive unavailable`. Fix `ARCHIVE_DIR`, then run `"$PY" -m mcap reprocess --pending`.
- **No note, but a transcript.** api mode: `"$PY" -m mcap api-key status` and `"$PY" -m mcap api-key check`; "credit exhausted" means the Console credit or spend limit is used up. subscription mode: `claude auth status`, then `claude auth login`. After fixing it run `reprocess --pending`.
- **The first meeting seems to hang.** If the model was not downloaded at install, the 3 GB download starts when the first meeting is processed. `--pre-download-model` avoids it.
- **Logs:** `~/Library/Logs/MeetingCapture/app.log` and `pipeline-<id>.log`. Set `LOG_CONTENT=0` before sharing any of them, and never attach recordings, transcripts or notes to an issue.

## Limitations

- Echo cancellation of the mic track (needed when you listen through speakers) is a heuristic checked on synthetic audio. It prefers keeping your voice over removing the echo.
- In a meeting room, a room microphone puts everyone in the room on the mic track, and they all get your `SELF_NAME` label. There is no speaker identification: all remote participants are `Remote`.
- Your microphone is recorded while you are muted in the meeting app.
- Closing the laptop lid puts the Mac to sleep: recording ends and processing pauses until it wakes up.
- Whisper can hallucinate text in silence; a filter removes the usual cases but not all. Mixed Korean and English speech is Whisper's weak spot (the vocabulary list and the cleanup pass help).
- Tested with Korean and English only. The app's own texts (notifications, menu hints, dialogs) are English by default and Korean with `UI_LANGUAGE=ko`; the language of the note body is `NOTE_LANGUAGE` and its headings stay English. The default Whisper prompt describes a medical-AI meeting (a mild domain bias).
- Only Zoom detection has been verified in real calls, on one setup. Teams, Meet and every other app are implemented from public signals and unit-tested with fakes. Treat the first weeks as a trial and compare the archive with your calendar now and then; the generic rule for other apps can record something that is not a call (use **Never record**).

## Organisation mode (experimental)

The repository also contains the pieces one organisation used to roll the app out to several Macs: a policy file that can only restrict, a signed installer package, MDM helper scripts and a central speech-to-text server. It is **experimental, written for a single organisation, mostly in Korean, not reviewed by a lawyer, and not needed for personal use**. None of the scripts signs, notarizes or uploads anything.

- Deployment and installer: [docs/DEPLOY.md](docs/DEPLOY.md) (`make pkg ARGS=--dry-run` prints the plan; `scripts/setup_python.sh --client-only` builds the client-only environment)
- Operations and incident response: [docs/OPS_RUNBOOK.md](docs/OPS_RUNBOOK.md)
- Moving from a personal install: [docs/MIGRATION.md](docs/MIGRATION.md)
- Policy file: [docs/POLICY.md](docs/POLICY.md); what leaves the Mac and when: [docs/PRIVACY_LANES.md](docs/PRIVACY_LANES.md)
- Speech server: [docs/ASR_PROTOCOL.md](docs/ASR_PROTOCOL.md), [docs/ASR_SERVER_LINUX.md](docs/ASR_SERVER_LINUX.md)

## Uninstall

```bash
scripts/uninstall.sh --dry-run        # look first
scripts/uninstall.sh                  # removes the login agent and the app; keeps your settings, sessions, models and logs
scripts/uninstall.sh --purge          # also deletes the support folder and logs (asks you to type 'purge')
sudo scripts/uninstall.sh --company   # organisation mode only: removes the installer package's files
```

Your meetings in `ARCHIVE_DIR`, the Hugging Face model cache, this folder and a signing identity are never touched. [docs/INSTALL.md](docs/INSTALL.md) lists the manual clean-up of permissions and the identity.

## Development

```bash
make help            # all targets
make build           # build/CATE.app with swiftc (the short name is MCAP_APP_SHORT_NAME)
make test            # device-free tests: shell scripts with stubs, Swift self tests, Python unittest
make lint            # bash -n and shellcheck (if installed) on all scripts
```

`make test-python` runs with the Python of the app's own environment when `make install ARGS=--python` has created it. On a Mac that has only the Command Line Tools (no Python 3.12 or newer, no numpy) install Python yourself and point the target at an interpreter that has numpy: `make test-python PY=/path/to/python3.13` (with the packages of `pipeline/requirements.client.txt`; [CONTRIBUTING.md](CONTRIBUTING.md) shows how to set up that environment).

The tests need no microphone, no permission prompt, no Keychain and no network, and CI runs them on GitHub Actions ([docs/RELEASING.md](docs/RELEASING.md) describes the workflows). They do not prove live recording: real capture, permissions and Zoom or Teams detection can only be checked on a real Mac ([docs/LIVE_TEST.md](docs/LIVE_TEST.md)). See [CONTRIBUTING.md](CONTRIBUTING.md). The design contract is [SPEC.md](SPEC.md), written in Korean during development; where it disagrees with the code and tests, the code wins.

## Roadmap

Ideas, not promises. Contributions are welcome.

- More languages for the app's own texts (`UI_LANGUAGE` offers English and Korean today).
- Fewer Korean-first defaults: a neutral Whisper prompt frame that can be overridden, after re-measuring accuracy.
- Hash-pinned installs as the documented default path (`make hash-lock`).
- Notarized builds, if a maintainer with an Apple Developer account takes it on (releases are ad-hoc signed and not notarized today).
- Verifying Google Meet detection on real calls, and detection for more meeting apps.

## Non-goals

- No video or screen recording, no live captions, no speaker identification beyond "you" and "remote".
- No hosted service, no account, no telemetry of its own. It runs on your Mac.
- No Intel Macs, older macOS releases, Windows or Linux clients. (The Linux speech server of the organisation mode is the one exception, and it is not a client.)
- No bot that joins meetings and no use of the platforms' own recording functions.
- No covert recording and no guarantee of legal compliance. Telling the participants stays your job.

## Trademarks and independence

Catch Everything is an independent open-source project. It is not affiliated with, endorsed by or sponsored by Zoom Communications, Microsoft, Google, Anthropic, Apple, OpenAI, Hugging Face, NVIDIA or any other company named in this repository. Zoom, Microsoft Teams, Slack, Cisco Webex, Discord, FaceTime, Skype, GoTo, Amazon Chime, BlueJeans, Lark, KakaoTalk, WhatsApp, JANDI, Whereby, Jitsi, Azure, Google Meet, Google Drive, Google Calendar, Google Chrome, Claude, Claude Code, macOS, Apple, Whisper, Qwen, Hugging Face, NVIDIA and CUDA are trademarks of their respective owners. They are used only to say which software this project works with. The project does not include their code, logos or SDKs. It observes meeting apps only through macOS process, audio and network-socket state and, if you enable Meet or `CALL_BROWSER_URLS`, the address of Chrome tabs.

Google Drive: the archive step copies ordinary files into a folder you choose (normally the Google Drive for desktop sync folder). It calls no Google API and holds no Google credentials. Everyone with access to that Drive folder, including workspace administrators, can open the audio, transcripts and notes.

Meeting platforms have their own terms and recording rules. Using this tool does not replace the platform's recording notice, and you must follow the platform's terms.

## License

Copyright 2026 Meeting Capture contributors. Licensed under the Apache License, Version 2.0, see [LICENSE](LICENSE). Third-party components and models keep their own licences: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The documentation in this repository is under the same licence.

Releases are built by `scripts/release.sh`: the source, a `SHA256SUMS` file and, when built on Apple silicon, an ad-hoc signed app zip that is **not notarized** (macOS quarantines a browser download of it; the release notes list the steps). Building from source is the recommended path. This project does not distribute Python packages, virtual environments or model weights: you download those yourself during the install.
