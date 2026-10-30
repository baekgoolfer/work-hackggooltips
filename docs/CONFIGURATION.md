# Configuration

Catch Everything (CATE) reads one file, `config.env`, in `~/Library/Application Support/MeetingCapture/`. `scripts/install.sh` creates it from
`config/config.env.example` and never overwrites an existing one. The example file is the annotated version of this page (English and
Korean comments), and a test checks that the two list the same keys with the same defaults.

Format: `KEY=VALUE`, one per line. `#` starts a comment at the start of a line or after a space. No quotes are needed (a value may contain
spaces). `~` is expanded. A key that is missing takes the default below, so a new key is added with one line. Both the Swift app and the Python
pipeline read the file; each ignores the keys it does not use.

When a change applies: keys of detection and recording and `UI_LANGUAGE` after the app is restarted (menu Quit, then
`open -n ~/Applications/CATE.app`, or `scripts/make_launchagent.sh --load`); `ASR_*`, `NOTE_*`, `MIC_AEC`, `TRANSCRIPT_CLEANUP`,
`AUDIO_*` and the other pipeline keys from the next processing run.

## Changing settings in the app

Menu-bar icon, **Settings…** (Cmd-,) edits twenty of the keys below in a window (`UI_LANGUAGE`, `ARCHIVE_DIR`, `SELF_NAME`, `CLAUDE_AUTH`, `NOTE_MODEL`,
`CLAUDE_DAILY_BUDGET_USD`, `CLAUDE_MEETING_BUDGET_USD`, `ASR_ENGINE`, `ASR_STRATEGY`, `ASR_CLOVA_INVOKE_URL`, `ASR_OPENAI_COMPAT_URL`, `ASR_OPENAI_COMPAT_MODEL`,
`ENABLED_PLATFORMS`, `CALL_DETECT`, `CALL_BROWSER_URLS`, `EXTRA_MEETING_APPS`, `OFFLINE_AUTOSTART`, `LOCAL_ONLY_DEFAULT`, `NOTIFY_RECORDING`, `LOG_CONTENT`) and
stores API keys in the Keychain. It changes only the lines you touch, keeps comments, blank lines, unknown keys and the quoting of a line, refuses values
the parsers would misread, writes a backup (`config.env.bak-settings-*`, the last five) before it replaces the file, and shows keys that an organisation
policy enforces as disabled. The consent of a cloud speech engine and the Google sign-in stay Terminal-only commands that the window opens for you.
Everything about it, tab by tab and where each value is stored: [SETTINGS.md](SETTINGS.md). Editing the file by hand keeps working.

## Where things live

| Name | Default location | Holds |
|---|---|---|
| `SUPPORT_DIR` | `~/Library/Application Support/MeetingCapture/` | `config.env`, `vocabulary.txt`, an optional `note_prompt.md` override, `venv/`, `bench-venv/` (benchmark only), `models/`, `sessions/<id>/` (staging), `usage.jsonl`, `overage.json`, `live-tested.confirmed` (written by `make confirm-live-tested`) |
| `LOG_DIR` | `~/Library/Logs/MeetingCapture/` | `app.log`, `pipeline-<id>.log`, `setup-report.txt`, `launchd-stdout.log`, `launchd-stderr.log` |
| `ARCHIVE_DIR` | `~/Meetings/` | `YYYY-MM/YYYY-MM-DD_HHMM_<title>/` with `transcript.md`, `transcript.cleaned.md`, `meeting-note.md`, `meeting-note.draft.md`, `audio.m4a`, `mic.m4a`, `remote.m4a`, `session.json`, `transcript.json` |
| App | `~/Applications/CATE.app` (`<short name>.app`, see [Names and identifier of the app](#names-and-identifier-of-the-app)) | bundle id `org.meetingcapture.app` (or your `MCAP_BUNDLE_ID`), signed ad hoc or with the local identity `MeetingCapture Local Signing` (the name of a certificate, not of the app) |
| LaunchAgent | `~/Library/LaunchAgents/<bundle id>.plist` | written only after `make confirm-live-tested` |
| Organisation install (pkg) | `/Applications/CATE.app` (the short name again), `/Library/LaunchAgents/<bundle id>.plist`, `/usr/local/bin/mcap`, `/Library/Application Support/MeetingCapture/` | all owned by root; see [DEPLOY.md](DEPLOY.md) |
| Hugging Face model cache | `~/.cache/huggingface/hub/` | the Whisper large-v3 model (3.08 GB) |

## Names and identifier of the app

Three build inputs say what the app is called and how macOS tells it apart from other apps. They are read when you build (`make build`, `make install`, `make dmg`, `make pkg`, `scripts/release.sh`); the app then reads them back from its own `Info.plist`, and the scripts and the Python pipeline learn them as described under "How each part finds the names".

| Input | Default | What it is | Rules |
|---|---|---|---|
| `MCAP_BUNDLE_ID` | `org.meetingcapture.app` | the identifier: the `CFBundleIdentifier`, the code-signing identifier, the login-agent label; the package identifier is `<id>.pkg` | reverse-DNS: dot-separated labels of letters, digits and hyphens, at least two labels, at most 155 characters |
| `MCAP_APP_NAME` | `Catch Everything` | the human name: `CFBundleDisplayName`, the name in the usage strings of `Info.plist`, in every message, menu item and notification of the app, and the volume name of the disk image | ASCII letters, digits, spaces, hyphens and periods; starts with a letter or digit; no trailing space; 1 to 40 characters |
| `MCAP_APP_SHORT_NAME` | `CATE` | the file-safe short name: the app folder `<short name>.app`, its program, `CFBundleName`, the disk image `<short name>-<version>.dmg` and the release zip | ASCII letters and digits only, starting with a letter, 1 to 32 characters |

An empty value counts as unset. A value that breaks a rule is refused with a message that names it, before anything is built or changed. The defaults and the rules live in one place, `scripts/bundle_id.sh`.

The defaults are shared by every copy built from this source, so they name nobody: with nothing set you get Catch Everything, `CATE.app` and `org.meetingcapture.app`. Whoever ships a build of their own sets their own id and names and keeps them for every later build ("Forks that distribute builds" in [CONTRIBUTING.md](../CONTRIBUTING.md)).

**How each part finds the names.** The app reads `CFBundleDisplayName` and `CFBundleName` from its own `Info.plist` when it runs (a bare binary and the self tests use the defaults). The scripts take them from the installed or built app's `Info.plist` first, then from `MCAP_APP_NAME` and `MCAP_APP_SHORT_NAME` in the environment, then from the defaults, the same way they find the bundle id. The Python pipeline takes them from the app that holds it (the disk-image install keeps the pipeline inside the app), else from the same two variables, else from the defaults. The app puts its own two names into the environment of every pipeline it starts, and the `mcap` shim of the company package sets them too, so a pipeline the app or the shim runs shows the same names as the app, wherever its folder is. Only a pipeline you start by hand from a checkout, without those variables, shows the defaults; it uses the human name in two places, the page that the Google sign-in ends on and the description line of the pipeline's command-line help.

**Why the id stays the same.** macOS ties the permissions (Microphone, System Audio Recording, Notifications) to the bundle id and the signature: a stable id keeps them across updates, a different id is a different app to macOS and asks again. `make install` refuses to replace an installed app that has another id (`MCAP_ALLOW_ID_CHANGE=1` to switch on purpose).

**Keep the names of a build you already run.** Set `MCAP_BUNDLE_ID`, `MCAP_APP_NAME` and `MCAP_APP_SHORT_NAME` to what the installed app already uses (`plutil -p ~/Applications/<file>.app/Contents/Info.plist` shows `CFBundleIdentifier`, `CFBundleDisplayName` and `CFBundleName`) and every later build keeps the same app file, program and id. An app file with another name next to the new one is refused by the install guard of `scripts/build_app.sh --install` (and so by `make install`) when both have the same bundle id: two apps with one id would share one login agent and one set of permissions. Remove or rename the old file, or build with its short name.

**What does not follow the names.** These are paths and identifiers, not the name of the product, and renaming them would orphan data and Keychain items that already exist: the data folder `~/Library/Application Support/MeetingCapture`, the organisation's `/Library/Application Support/MeetingCapture`, the log folder `~/Library/Logs/MeetingCapture`, the Keychain services (`MeetingCapture Anthropic API key`, `MeetingCapture ASR <engine>` and the like), the Python package `mcap`, the `MCAP_*` variables, the config keys, and the labels of the login agent (the bundle id) and of the speech server's LaunchDaemon (`org.meetingcapture.asr`, separate from the app's id).

`session_id` is `YYYY-MM-DD_HHMM_<zoom|teams|meet|manual>`. A recording is written to staging (`sessions/`) only; the finished folder is moved to
`ARCHIVE_DIR` once processing is done. `mic.wav` / `mic.m4a` is the microphone track (its label in the transcript is `SELF_NAME`),
`remote.wav` / `remote.m4a` the system audio.

To archive into Google Drive for desktop (or any other synced folder), set `ARCHIVE_DIR` to a folder inside it, for example
`ARCHIVE_DIR=~/Library/CloudStorage/GoogleDrive-<your-account>/My Drive/Meetings`. `scripts/install.sh` writes that line itself when exactly one
Google Drive account is mounted. Everyone with access to that Drive folder can open the audio, the transcripts and the notes.

## Settings (`config.env`)

| Key | Default | Meaning |
|---|---|---|
| `ARCHIVE_DIR` | `~/Meetings` | Where finished meetings are filed. A plain local folder by default; a synced folder (Google Drive, a shared drive) when you set it |
| `PROJECT_DIR` | `~/Developer/meeting-capture` | This repository: the app starts the pipeline from `PROJECT_DIR/pipeline` and the prompts are read from here. `install.sh` fills in the checkout it runs from; if you move the clone, change this line too |
| `PYTHON_BIN` | `<SUPPORT_DIR>/venv/bin/python` | Python of the pipeline venv |
| `CLAUDE_BIN` | `~/.local/bin/claude` | The Claude Code command line tool (install it yourself; `install.sh` prints the path it finds if it is elsewhere) |
| `CLAUDE_AUTH` | `api` | Who pays for the Claude calls: `api` = an Anthropic Console API key from the macOS Keychain, billed per token (`make set-api-key`); the default and the supported path. `subscription` = your own Claude login (`claude auth login`); opt-in, and you must check Anthropic's terms for unattended `claude -p` first. A wrong value fails without making a call. See the README section on Claude |
| `CLAUDE_KEY_SERVICE` | `MeetingCapture Anthropic API key` | Keychain generic-password service of the API key (account = your login name) |
| `CLAUDE_DAILY_BUDGET_USD` | `5` | api mode: when today's cost reaches this many USD, the later Claude stages of the day stop (the note fails with `budget_daily`, the transcript is still filed, processing resumes at midnight). `0` = off |
| `CLAUDE_MEETING_BUDGET_USD` | `2` | api mode: when one processing run reaches this cost, cleanup, verification and the calendar lookup are skipped (the note is always reserved). `0` = off |
| `SELF_NAME` | `Me` | Label of your microphone track in transcripts and notes. Set it to your name |
| `UI_LANGUAGE` | `en` | Language of the app's own texts (notifications, menu hints, dialogs): `en` or `ko`. Unknown text means `en` |
| `ENABLED_PLATFORMS` | `zoom,teams` | Which of Zoom, Teams and Google Meet are detected automatically. **`meet` is off by default** (`zoom,teams,meet` turns it on; see below). It does **not** limit the calls of other apps: `CALL_DETECT` does (a narrow list such as `zoom` still records a Slack huddle or a FaceTime call under `CALL_DETECT=known`). Empty (`=`) = no automatic detection at all, only manual recording (the call rule is off too) |
| `BROWSER_BUNDLE_IDS` | `com.google.Chrome` | Browsers that can host Google Meet (used only when `meet` is enabled, or for `CALL_BROWSER_URLS`; a browser is never taken for a call app) |
| `CALL_DETECT` | `known` | Calls of other apps ([docs/DETECTION.md](DETECTION.md) section 3b). `known` = a built-in table of call apps (Slack huddles, Webex, Discord, FaceTime, KakaoTalk, WhatsApp, ...) plus `EXTRA_MEETING_APPS`, no guessing; `generic` = **opt in, it guesses**: those and any other GUI app that is not on the built-in deny list and not denied by you, once it has held the microphone **and** played sound for `CALL_GENERIC_SECONDS` (it records and posts a notification naming the app); `off` = none of this. Menu **Never record `<App>`** and the **Call Apps** submenu change your decision per app, kept in `call-apps.json`. Any other text reads as `known`. On a Mac with an organisation policy a `CALL_DETECT` that neither `config.env` nor the policy sets means `off`. Zoom, Teams, Meet and manual recording are not affected; an empty `ENABLED_PLATFORMS` switches it off too. Only Zoom has been verified in real calls |
| `CALL_GENERIC_SECONDS` | `45` | `generic`: how long an app has to hold the microphone and output together before it counts (10 to 600; a gap of 3 s starts over). The recording starts a few seconds later (start debounce) |
| `EXTRA_MEETING_APPS` | `<none>` | More call apps for `known` and `generic`: comma separated bundle ids, each `id` or `id=Display Name` (`com.example.talk=Example Talk`). Find an id with `mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app`. Garbage, duplicates, browsers, Zoom, Teams and this app are dropped with a line in `app.log`; at most 64 entries. The built-in deny list does not apply to them |
| `CALL_BROWSER_URLS` | `off` | `on` = also read the address of Chrome tabs for meeting pages of Whereby, Jitsi, Webex web, Teams web and the Zoom web client. It needs the Chrome Automation permission (like Google Meet), so it is off: nobody who uses native apps only is asked. Google Meet stays behind `meet` in `ENABLED_PLATFORMS`. `1`/`0`, `true`/`false`, `yes`/`no`, `on`/`off` |
| `POLL_INTERVAL_SECONDS` | `2` | Detection polling interval |
| `START_DEBOUNCE_SECONDS` | `4` | A meeting signal must last this long before recording starts |
| `GRACE_SECONDS` | `20` | After the signal disappears, wait this long before stopping (at least 30 s for Zoom, Teams and the calls of other apps) |
| `MIN_RECORDING_SECONDS` | `30` | Recordings shorter than this are treated as short (only recordings under 10 s are actually discarded) |
| `MAX_RECORDING_HOURS` | `6` | Safety stop: a recording ends after this many hours |
| `MIN_FREE_DISK_GB` | `5` | Recording does not start, or stops, when less disk is free |
| `NO_SPEECH_STOP_MINUTES` | `15` | An automatic recording ends normally (and is kept) when both tracks stay below -70 dBFS (digital silence) this many minutes; 1 to 600. Room noise prevents it. `0` = off |
| `RETRY_SWEEP_HOURS` | `6` | While failed but retryable sessions exist, the app runs `mcap reprocess --pending` at this interval (0.25 to 168 hours). `0` = off |
| `NOTIFY_RECORDING` | `1` | A macOS notification when a recording starts and ends (in case the menu-bar icon is hidden). `0` = off. Warnings and results are always shown |
| `SYSTEM_AUDIO_MODE` | `global` | `global` = all system output except this app, `app` = only the meeting app's processes (records less sound) |
| `ASR_MODEL` | `mlx-community/whisper-large-v3-mlx` | Transcription model (a Hugging Face repo id or a local folder) |
| `ASR_LANGUAGE` | `auto` | `auto` (language detected per region), `ko`, `en` |
| `ASR_LANGUAGES` | `ko,en` | The languages that the per-region language detection and the foreign-script filter follow. **Add `ja` for Japanese meetings** (`ko,en,ja`): without it kana and kanji are dropped as foreign script. The defaults were tested with Korean and English only |
| `ASR_VAD` | `auto` | Voice activity detection: `auto` (Silero when installed, else the energy detector), `silero`, `energy` |
| `ASR_STRATEGY` | `dual` | `dual` = every chunk is decoded twice by the same local model (with and without the vocabulary prompt) and the two answers are merged by fixed rules; about 1.5 to 1.8 times the transcription time, local Whisper only (an external engine always runs `single`). `single` = one decode per chunk with the prompt, faster. Unknown text reads as `single`. See "Transcription strategy" below |
| `MIC_AEC` | `auto` | Offline echo cancellation of the microphone track: `auto` (only when the speakers leak into the mic), `1` (always), `0` (never) |
| `TRANSCRIPT_CLEANUP` | `1` | An LLM pass that writes `transcript.cleaned.md` (the raw transcript is never modified) |
| `NOTE_VERIFY` | `1` | A second pass that checks the draft note against the raw transcript |
| `NOTE_MODEL` | `opus` | Model alias of the note (the same alias in api mode) |
| `NOTE_FALLBACK_MODEL` | `sonnet` | Tried once when the main model fails |
| `NOTE_EFFORT` | `high` | `claude --effort` |
| `NOTE_LANGUAGE` | `auto` | Language of the note body: `auto` (the main language of the meeting), `ko`, `en` |
| `NOTE_TIMEOUT_SECONDS` | `1200` | Time limit of one Claude call |
| `NOTE_STOP_ON_OVERAGE` | `1` | Subscription mode only (ignored in api mode): `1` = stop writing notes while Claude reports extra-usage billing and keep only the transcript; `0` = allow extra usage on purpose and only record it. Use exactly `1` or `0` |
| `MAX_CLAUDE_CALLS_PER_MEETING` | `30` | Upper limit of `claude -p` calls for one meeting (cleanup batches + note + verification + calendar) |
| `CALENDAR_LOOKUP` | `0` | `auto` or `0` (the example file ships `0`; without the key the built-in value is `auto`): ask the claude.ai Google Calendar connector for the title and attendees (only events within 45 minutes of the recording start; a failure falls back to the window title or the platform name). While on, the title and attendees of those events pass through Claude. This one call always runs on the subscription login, also when `CLAUDE_AUTH=api`. It does nothing without a claude.ai login that has the connector |
| `AUDIO_RETENTION_DAYS` | `0` | `0` = keep audio forever. N > 0: after each processing run, delete the `*.m4a` of meetings older than N days (transcripts and notes are never deleted) |
| `LOCAL_ONLY_DEFAULT` | `0` | Default of the per-meeting "local-only" switch for new recordings. `1` = a new recording is transcribed on this Mac only and skips the five lanes that can leave it (remote and cloud ASR, Claude cleanup/note/verification, the calendar lookup, the archive upload); it is kept in `LOCAL_ARCHIVE_DIR`. Unknown text reads as `1`. An organisation policy can raise or lock it |
| `ASR_ENGINE` | `whisper` | Primary transcription engine: `whisper` (local), `remote` (an `mcap-asr` server of your organisation), `azure`, `clova` (NAVER CLOVA Speech), `openai-compat` (a server of your choice with the OpenAI transcription API), `auto` (whisper when this Mac can run it). An external engine is used only when the meeting is not local-only, the policy allows it, a consent exists and it is named here or in `ASR_FALLBACK`. Unknown text means whisper |
| `ASR_FALLBACK` | `none` | Engine that takes over a chunk when the primary fails (never chained): `none`, `whisper`, `remote`, `azure`, `clova`, `openai-compat` |
| `ASR_LOCAL_MIN_RAM_GB` | `16` | Minimum RAM (GB) of the "can transcribe locally" verdict (engine `auto` and doctor) |
| `ASR_LOCAL_MAX_RTF` | `0.25` | Maximum measured real-time factor of the same verdict (`mcap asr-engines check --probe`) |
| `ASR_ALLOW_DOWNLOAD` | `1` | `1` = the model may be downloaded when it is missing. Always 0 for a local-only run; an organisation baseline policy forces 0. Unknown text reads as `0` |
| `ASR_REMOTE_URL` | <empty> | Address of an `mcap-asr/1` server: https and a DNS name only. Host and port must match a consent (or organisation consent) and the policy's `allowed_hosts`; the Keychain token is bound to this host:port |
| `ASR_REMOTE_CA_FILE` | <empty> | PEM of the private CA that signs the server certificate; for that host only this CA is trusted and the file's sha256 must equal the consent's `ca_sha256` |
| `ASR_REMOTE_MAX_WAIT_S` | `120` | The longest one chunk waits in total (retries, `Retry-After`, queue) |
| `ASR_AZURE_REGION` | `koreacentral` | Region of the Azure Speech resource. Changing it voids the consent. The engine only uses `koreacentral` and `koreasouth`; any other region is refused before anything is sent |
| `ASR_AZURE_HOST` | <empty> | A custom endpoint host (it must end in `.api.cognitive.microsoft.com` or `.cognitiveservices.azure.com`). Empty = built from the region. A `.cognitiveservices.azure.com` host does not name its region, so `ASR_AZURE_REGION` must be written explicitly too |
| `ASR_AZURE_LOCALES` | <empty> | Candidate locales (`ko-KR,en-US`). Empty = omitted (multilingual model) |
| `ASR_AZURE_BIAS` | `1.0` | Weight of the vocabulary terms in the phrase list (0.0 to 2.0; only when `ASR_SEND_VOCAB` is on) |
| `ASR_AZURE_USD_PER_HOUR` | `0` | Hourly price in USD used only for the `est_usd` estimate in `asr-usage.jsonl`. 0 = unknown. The real bill is in Azure Cost Management |
| `ASR_CLOVA_INVOKE_URL` | <empty> | Invoke URL of your own CLOVA Speech domain (`https://clovaspeech-gw.ncloud.com/external/v1/<id>/<key>`): https and a NAVER Cloud gateway host (`.ncloud.com`, `.fin-ncloud.com`, `.gov-ncloud.com`) only. Host and port are bound into the consent and the Keychain key (changing the host voids both); the path is your domain and is never logged or stored. The secret key is stored with `mcap asr-engines secret set clova` |
| `ASR_CLOVA_LANGUAGE` | `enko` | `ko-KR`, `en-US`, `enko` (Korean and English in one request), `ja`, `zh-cn`, `zh-tw`. `ASR_LANGUAGE` is not used by this engine. Unknown text reads as `enko` |
| `ASR_CLOVA_DIARIZATION` | `auto` | Speaker separation: `on`, `off`, or `auto` = on for the only track of a meeting (an offline meeting) and for the remote track of an online meeting, off for the microphone track of an online meeting |
| `ASR_OPENAI_COMPAT_URL` | <empty> | Base URL of a server that implements `POST <base>/audio/transcriptions` (OpenAI itself, a faster-whisper server, your own gateway): https and a DNS name, never an IP address. The destination is YOUR choice: the consent names the host, a company policy needs `asr.allow_foreign`. Host and port are bound into the consent and the optional Keychain key |
| `ASR_OPENAI_COMPAT_MODEL` | `whisper-1` | The `model` field of that request: one printable token without blanks, up to 100 characters (an id such as `Systran/faster-whisper-large-v3` is fine) |
| `ASR_CLOUD_BLOCK_SECONDS` | `900` | Seconds of speech in one upload of an engine that takes blocks (`clova`, `openai-compat`), 30 to 1800; `openai-compat` never uses more than 720 (OpenAI takes 25 MB per file, 720 s of this WAV are 23 MB). See "Cloud providers" below |
| `ASR_CLOUD_DAILY_MINUTES` | `240` | Daily cap (minutes, audio seconds + 1 s per request) of audio sent to external engines from this Mac; the smaller of this and the policy cap applies. Advisory on the client: the server's per-token quota is authoritative |
| `ASR_REQUEST_TIMEOUT_S` | `90` | Time limit of one ASR HTTP request (seconds; keep it above the server queue cap of 45 s plus service time) |
| `ASR_RETRY_MAX` | `3` | Attempts per chunk inside an external engine |
| `ASR_CIRCUIT_FAILS` | `3` | Circuit breaker: this many consecutive transient failures open it for the rest of the run |
| `ASR_CIRCUIT_COOLDOWN_S` | `120` | Wait before one probe chunk goes to the primary engine again (doubled each time it opens again, at most 600) |
| `ASR_SEND_VOCAB` | `1` | `1` = the `vocabulary.txt` terms are sent to an external engine (the consent text says so). Local Whisper always uses the full list. A policy can switch it off per engine kind. Unknown text reads as `0` |
| `LOCAL_ARCHIVE_DIR` | <default: `SUPPORT_DIR/local-meetings`> | Where local-only (and archive-denied) meetings are kept. It must be under `SUPPORT_DIR` (or a folder the policy allows), contain no link and be on the same disk as your home folder, else `local_archive_unsafe`. An organisation policy cannot set this key |
| `LOCAL_ARCHIVE_RETENTION_DAYS` | `0` | `0` = keep. N > 0: delete the `*.m4a` of local-archive meetings older than N days (transcripts are never deleted) |
| `STAGING_FAILED_RETENTION_DAYS` | `0` | `0` = keep. N > 0: delete non-retryable failed sessions in staging older than N days |
| `MIC_MUTE_GATE` | `off` | `off` or `on`. `on` = while a positive mute signal holds, zeros are recorded for the microphone (an unknown signal records). Read by the app. Unknown text reads as `on`. An organisation baseline policy forces `on` |
| `LOG_CONTENT` | `1` | `1` = pipeline logs hold transcript snippets (60 characters at most) and the app log holds meeting titles. `0` = only lengths and short hashes, and no titles or slug paths in notifications and the app log. Unknown text reads as `0`. **Set `0` before you attach a log to an issue.** An organisation baseline policy forces `0` |
| `LOG_RETENTION_DAYS` | `0` | `pipeline-*.log` older than this many days are deleted when processing (`0` = keep). The organisation baseline default is 30 |
| `APP_LOG_MAX_MB` | `0` | Rotation size of `app.log` in MB (5 files kept, `0` = no rotation). Read by the app only. The organisation baseline default is 5 |
| `STATUS_INCLUDE_USAGE` | `0` | `1` = `mcap status --write` (the MDM extension attribute) also reports the coarse `asr_usage_7d` and `llm_cost_7d_usd`. `0` = device health only. `mcap status` in a terminal always shows everything |
| `OFFLINE_AUTOSTART` | `off` | `off` or `auto`. `auto` = the app starts a recording by itself for an in-person conversation that is in your Google Calendar (see "Calendar autostart" below and [CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md): **it records whoever is in the room**). Any other text reads as `off`. Read by the app; needs `python -m mcap gcal auth` once |
| `OFFLINE_START_BEFORE_MINUTES` | `2` | A recording may start this many minutes before the event starts (0 to 30) |
| `OFFLINE_START_AFTER_MINUTES` | `15` | ... and up to this many minutes after it started (0 to 120): an event that began earlier than that is not joined late (a recording that a sleep of the Mac or a quit of the app interrupted is picked up again while the event runs, whatever this says) |
| `OFFLINE_STOP_AFTER_END_MINUTES` | `10` | A recording that this feature started stops this many minutes after the event's end (0 to 120) |
| `OFFLINE_IDLE_MAX_MINUTES` | `5` | No keyboard or mouse input for longer than this many minutes (1 to 120) means nobody is at the Mac: no automatic start |
| `OFFLINE_REQUIRE_GUESTS` | `1` | `1` = the event needs at least one attendee besides you (`guests` of `gcal upcoming` is at least 1); `0` = no such condition |
| `OFFLINE_MIN_MINUTES` | `10` | Events shorter than this many minutes (1 to 600) are never recorded |
| `OFFLINE_MAX_MINUTES` | `240` | Events longer than this many minutes (1 to 1440) are never recorded; `OFFLINE_MIN_MINUTES` must not exceed it |

`config/config.env.example` has the same keys and defaults (`make test-scripts` checks it). The keys from `LOCAL_ONLY_DEFAULT` to
`STATUS_INCLUDE_USAGE` (the privacy lanes, SPEC 18) are commented out in the example as `# KEY=default`: remove the `#` to change one.
**Every one of them defaults to the behaviour of a Mac without an organisation policy.** An unrecognised switch text reads as the restrictive value of
that key (`LOCAL_ONLY_DEFAULT` on; `ASR_ALLOW_DOWNLOAD`, `LOG_CONTENT`, `ASR_SEND_VOCAB` off; `MIC_MUTE_GATE` on).

Secrets (an Azure key, a relay token, the Anthropic API key, the Google Calendar token) are never written to this file: they live in the macOS Keychain. The keys of an
organisation policy (`lanes`, `approvals`, `local_only`, `defaults`, `enforced`, ...) are in `policy.json`, not here ([POLICY.md](POLICY.md)). A `1`/`0`
key such as `TRANSCRIPT_CLEANUP` or `NOTE_VERIFY` is quietly read as off when you mistype it, so write the value exactly.

## Calendar autostart (`OFFLINE_*`)

**Warning.** With `OFFLINE_AUTOSTART=auto` the app starts a recording **without you pressing anything**, for every in-person conversation that your Google
Calendar says is happening and that passes the checks below. It records whoever is in the room. Recording people can require their consent and can
be a crime where you are; a calendar entry is not their consent. Read [CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md) (the warning, the setup in the
Google Cloud console, what is read and sent, how to revoke) before you set it. It is a single-user feature, **off by default**, and the `OFFLINE_*` keys
cannot be set by an organisation policy.

The app asks `python -m mcap gcal upcoming --from-minutes N --to-minutes M` (read-only Google Calendar, your own OAuth client, the token only in
the Keychain) which events are around now and decides with these keys: a start window around the event's start, an idle check of the Mac, the
minimum number of other attendees, the event length limits, and when to stop. The app has its own gates on top of these keys (the recording switch of an organisation
policy, a locked policy, the local-only default), and the organisation's `calendar` lane closes `gcal` itself (`lane_denied`). Only events that you take part in are
considered: you organised or created them, or you answered yes or maybe; **an invitation you have not accepted never starts a recording**.
`config/config.env.example` has the keys as commented lines (`# OFFLINE_AUTOSTART=off`); remove the `#` to change one. An invalid number keeps the default
and is logged.

## Language

- `UI_LANGUAGE` (`en` or `ko`) sets the language of the notifications, menu hints and dialogs. The Korean texts are kept word for word.
- `NOTE_LANGUAGE` (`auto`, `ko`, `en`) sets the language of the note body; the headings of the note are always English.
- `ASR_LANGUAGES` lists the languages the transcription may use. It was tested with Korean and English only; add other languages (for example
  `ko,en,ja`) or their script is filtered out as foreign.
- The Whisper prompt starts from a short framing sentence about a medical AI meeting plus your vocabulary (`config/vocabulary.txt`); the
  vocabulary is the way to bias the recognition toward your own terms.

## Transcription strategy

`ASR_STRATEGY` chooses how often each chunk of speech is decoded.

- `single`: one decode per chunk with the vocabulary prompt (a language frame plus your terms). A chunk that looped or parroted the prompt is retried once without it.
- `dual`: that decode is pass P. Pass N decodes the same chunk in the same language **without** a prompt. `pipeline/mcap/asr_reconcile.py` then merges the two answers of each chunk before the post-filters and the echo check, with fixed rules (no model, nothing is sent anywhere):
  1. P and N segments are paired by time (overlap divided by the shorter duration is at least 0.3; one P segment against three N segments is one group);
  2. a group that reads the same after normalisation (case, punctuation, spaces) keeps P;
  3. otherwise each side scores one point per vocabulary term it contains and loses one per implausible number; the higher score wins. On equal scores N wins only for a pure figure disagreement: both sides plausible, the digits differ, both carry the same number of digit tokens (a figure that N spells out or drops is lost content) and N has at least 80% of P's words (a truncated answer never replaces a fuller one); every other tie goes to P. A side with a looped segment (compression ratio above 2.4) loses to a clean one;
  4. an N segment with no P counterpart is added back when it lasts at least 0.4 s, has `avg_logprob >= -0.9` and `no_speech_prob <= 0.5`, and is not a repeat of the segment next to it (this is how a short "네" survives);
  5. a P segment with no N counterpart is kept.

  An implausible number is a deliberately narrow guess at what a vocabulary prompt can do to a figure: a figure written with a thousands separator whose value exceeds 10^12 won before 만/억/조/경 (`80,000억`, `400,000억`), or an unseparated run of four or more digits before `억` (`4000억`). `400억`, `83억`, `1,200억` and `13조` are never flagged. The limits are constants at the top of `asr_reconcile.py`.
- Only a local engine that takes the prompt and reports log-probs runs `dual`. `remote`, `azure` and every other external engine ignore the key and run `single` (no audio is sent twice), as do `prompt_style none` and an empty `vocabulary.txt` (without a prompt the two decodes would be the same).
- Cost: the transcription step takes about 1.5 to 1.8 times as long (measured: 1.5 to 1.75; VAD, language ID and the model load are not repeated). A `config.env` that sets `ASR_STRATEGY=single` keeps `single`: only an install without the key, or with `dual`, runs the second pass.
- `single` writes nothing new into `transcript.json`. A `dual` run adds `stats.<track>.strategy` and `stats.<track>.dual`, and an `asr` block `{"schema": 1, "engine": ..., "kind": "local", "strategy": "dual", "dual": {"chunks", "conflicts", "plain_chosen", "restored"}}` (`conflicts` = groups whose two sides differed, `plain_chosen` = how many of them the plain decode won, `restored` = N-only segments added back). `transcript.md` has no extra line.
- Measure it on your own recording before you switch: `python scripts/bench_asr.py --audio meeting.m4a --start 660 --duration 720 --strategy both --models mlx-community/whisper-large-v3-mlx --language-mode auto-region --no-download --out benchmarks/strategy-660` for several slices, then `python scripts/bench_asr.py --gate-from benchmarks/strategy-*`. The script reports segments, English words, digit tokens, implausible numbers, repeated 4-word loops and transcription time per strategy and prints whether `dual` passes the rules below on every slice.

The default is `dual`. The rule for making it the default is measured, not assumed: on every slice of a real recording `dual` must produce no more implausible numbers than `single`, at most one English word fewer, no fewer segments, no new repeated 4-word loops, at most one digit token fewer and at most 2% fewer words (nothing spoken may get lost), in at most 2.4 times the transcription time. It was measured on three 12-minute slices (start 660, 4560 and 6960 s) of one private Korean/English business recording (Whisper large-v3, language ID per region, Silero VAD), with the final reconcile rules, in two runs. `dual` met every rule on every slice in both:

| vocabulary | slice | segments single / dual | words single / dual | implausible numbers single / dual | time dual / single |
|---|---|---|---|---|---|
| seed `config/vocabulary.txt` (11 example terms, none of them spoken) | 660 | 148 / 148 | 1303 / 1303 | 0 / 0 | 1.51 |
| | 4560 | 145 / 145 | 1245 / 1245 | 0 / 0 | 1.64 |
| | 6960 | 132 / 132 | 1295 / 1295 | 0 / 0 | 1.73 |
| 50 public regulatory and medical-AI terms (the size of a real vocabulary) | 660 | 168 / 168 | 1325 / 1328 | 2 / 0 | 1.68 |
| | 4560 | 165 / 170 | 1266 / 1307 | 0 / 0 | 1.75 |
| | 6960 | 157 / 157 | 1343 / 1343 | 0 / 0 | 1.75 |

English words (21, 10, 74 and 25, 9, 72), digit tokens (32, 38, 11 and 32, 40, 11) and repeated 4-word loops (none) were the same for both strategies on every slice. With the seed list `dual` wrote exactly the transcript of `single` and only cost time: of 217 groups in which the two decodes read differently the plain one won none and it had no segment to add back. With the 50-term list the plain decode won 1 of 230 such groups (the one where the prompt had bent a figure: both implausible numbers of the first slice are gone) and 5 of its segments, all in the second slice, were added back as short utterances. The gain is small and depends on the vocabulary, the price is the extra time, and one recording is a small sample. Set `ASR_STRATEGY=single` if speed matters more; measure on your own recordings with the command above before you decide for a group of machines.

## Cloud providers: CLOVA and OpenAI-compatible

Two cloud engines are built on one small provider layer (`pipeline/mcap/asr_providers.py`; adding a vendor is described in [ADD_A_PROVIDER.md](ADD_A_PROVIDER.md)). Both are **off** until you name them in `ASR_ENGINE` (or `ASR_FALLBACK`) and type a consent, and both go through the same gates as every external engine: a local-only meeting sends nothing, an organisation policy (lane `asr_cloud`, `allowed_engines`, `allowed_hosts`, and `allow_foreign` for a destination you chose yourself) can only restrict, the request goes through the egress guard (https only, no redirects, exactly the consented host and port).

To use one, three steps. 1. Write its URL in `config.env` (`ASR_CLOVA_INVOKE_URL`, or `ASR_OPENAI_COMPAT_URL` and `ASR_OPENAI_COMPAT_MODEL`). 2. `mcap asr-engines secret set clova` (or `openai-compat`) and type the API key in the terminal: it goes to the Keychain, bound to that host and port, and nowhere else (for a self-hosted server without a key skip this step). 3. `mcap asr-engines consent clova`, then set `ASR_ENGINE=clova`. `mcap asr-engines list` shows every engine with its settings status (never the key or your domain), `mcap asr-engines check clova` checks the setup without sending anything and `check clova --live` sends one synthetic tone.

- **What is sent.** A block of speech: the VAD chunks of one track (microphone first, then the remote side) are joined with the pauses cut out into blocks of up to `ASR_CLOUD_BLOCK_SECONDS` seconds (16 kHz mono WAV, file name `block.wav`), one request per block. The vendor bills every request rounded up (CLOVA: 15 s steps), so a few long requests cost less than many 28 s ones. Nothing else goes: no title, session id, platform or attendees. In `transcript.json` the `asr` block of such a run counts blocks in `chunks` and the audio seconds in `sent`, and `stats.<track>.blocks` / `block_audio_s` say the same per track (no content, no host). CLOVA also gets the vocabulary terms as `boostings` (one-character terms and terms in other scripts are left out, at most 1000) when `ASR_SEND_VOCAB` and the policy allow it; the OpenAI-style engine sends no vocabulary.
- **Billing is yours.** This program sets no budget and prices nothing: the vendor bills you. It writes the audio seconds of every request to `asr-usage.jsonl` (`mcap usage`) and keeps the existing daily cap `ASR_CLOUD_DAILY_MINUTES` (default 240 minutes of audio per day for all external engines together, advisory: you can raise it or delete the file).
- **Blocks and time.** A block is answered by one request, so its time limit is the larger of `ASR_REQUEST_TIMEOUT_S` and 60 s plus the audio seconds of the block (at most 600 s). A transient failure (connection, 5xx, 429 after `Retry-After`) of the primary sends a block to `ASR_FALLBACK` only when the fallback takes audio of that length. A local Whisper, an Azure or a company-server fallback takes 28 s, so the block is taken apart and its chunks are decoded one by one, each with its own language detection (and, for Whisper, the vocabulary prompt); any other failure loses only that block. A longer block means fewer rounded-up requests and a bigger loss when one fails. If a service refuses a block as too large (HTTP 413) the engine remembers it for the rest of the run: that block goes out again in blocks of half the size and later blocks are packed at that size. If the gateway gives up on a block (5xx or a time-out every time), lower `ASR_CLOUD_BLOCK_SECONDS` (300 is a safe start).
- **Language.** CLOVA reads `ASR_CLOVA_LANGUAGE` (default `enko`, Korean and English in one request) and ignores `ASR_LANGUAGE`; the language of a block in the transcript is the one with the most speech in it. The OpenAI-style engine lets the server detect the language unless `ASR_LANGUAGE=ko` or `en` pins it (Whisper servers cope best with `ko` for mixed Korean and English).
- **Speakers.** `ASR_CLOVA_DIARIZATION=auto` asks CLOVA to separate speakers on the only track of a meeting and on the remote track of an online meeting, not on the microphone track of an online meeting. The speaker labels are read but the transcript still labels a track as `SELF_NAME` or `Remote`.
- **Not verified.** The answer of a sync CLOVA call is not described by the public documentation the code was written from, whether a sync request of 900 s finishes inside the gateway's own time limit is unknown, and the OpenAI-style servers differ in details. The test fixtures say so; the first real call confirms the shapes (`mcap asr-engines check clova --live`).

## Calls of other apps (optional tuning)

Detection of Slack huddles, Webex, Discord, FaceTime, KakaoTalk, WhatsApp and the other apps of the built-in table is on by default (`CALL_DETECT=known`). It includes **personal messengers** (Discord, FaceTime, KakaoTalk, WhatsApp, Skype): a call in one of them is recorded like any other call, with the microphone and, in the default global mode, all system audio. If you do not want that, switch the app off (below) or set `CALL_DETECT=off`.
**Guessing is not on by default:** `CALL_DETECT=generic` also records any other GUI app that holds the microphone and plays sound for `CALL_GENERIC_SECONDS`, which can be a game with voice chat or an audio tool the deny list does not know. An existing `config.env` without `CALL_DETECT` gets `known` (the example file spells it out).
Zoom is the only platform that has been verified in real calls; everything else is implemented from public signals and unit-tested with fakes ([DETECTION.md](DETECTION.md) section 3b has the table, the evidence per app and what is unverified).

- **What `ENABLED_PLATFORMS` does and does not do:** it lists Zoom, Teams and Meet. It does not bound the calls of other apps: `ENABLED_PLATFORMS=zoom` still records a Slack huddle under `CALL_DETECT=known` (an empty list switches everything off). To keep an install to Zoom and Teams, set `CALL_DETECT=off`.
- **Only the table, no guessing:** `CALL_DETECT=known` (the default). **Guess too:** `CALL_DETECT=generic`. **None of it:** `CALL_DETECT=off`. Restart the app after a change.
- **An app that is not in the table:** add its bundle id to `EXTRA_MEETING_APPS` (`mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app`), for example `EXTRA_MEETING_APPS=jp.example.works=Example Works`.
- **An app you do not want recorded** (a messenger of the table, an extra app, a meeting page, or a guessed app): the **Call Apps** submenu lists every app of the table, your extra apps, the meeting-page sites (with `CALL_BROWSER_URLS=on`) and every other app that was recorded; one click flips an app between recorded and never record, **also before its first call**. While a call is recorded the menu has **Never record `<App>`** (it stops the recording and the app is not recorded again); a guessed app also announces itself with a notification that names it. A meeting page is kept per site (`web:whereby`), never as the browser's own id.
  The decisions are in `~/Library/Application Support/MeetingCapture/call-apps.json` (mode 0600; `{"version": 1, "apps": {"<bundle id>": {"decision": "allowed" | "denied", "name": "...", "updated": "..."}}}`; no titles). Delete the file to forget them all.
  The list **fails closed**: a file that exists but cannot be read (not JSON of that shape, empty, no read permission, a directory) pauses **every** call of another app (Zoom, Teams and Meet are not affected; the menu and `app.log` say why) and is never overwritten; fix or remove it and open the menu. An entry whose decision is not `allowed` or `denied` (a typo such as `"deny"`) is read as `denied`, and only an entry that says `allowed` allows. A decision whose write fails (a read-only folder) stays in force until the app quits and is written again once the file can be written.
- **Meeting pages in Chrome:** `CALL_BROWSER_URLS=on`, then run `setup` again for the Chrome Automation prompt (the same permission as Google Meet). Without it Chrome is never asked for anything. Google Meet is separate (next section) and stays off.
- **One recording at a time.** A Slack huddle (or any call of another app) that is on does not stop a Zoom, Teams or Meet meeting from being recorded: once such a meeting has been in its call for the start debounce, the call recording is ended and the meeting is recorded. A running Zoom, Teams or Meet recording is never taken over by a call app.
- **A company install:** all four keys (`CALL_DETECT`, `CALL_GENERIC_SECONDS`, `EXTRA_MEETING_APPS`, `CALL_BROWSER_URLS`) are on the policy whitelist, so a policy can set them in `defaults` or lock them in `enforced` (`"enforced": {"CALL_DETECT": "off"}`). On a Mac with a policy a `CALL_DETECT` that neither `config.env` nor the policy sets means `off`: a baseline of `ENABLED_PLATFORMS=zoom,teams` records only Zoom and Teams. With `recording.enabled=false` a call of another app is skipped with a line in `app.log` and no "Recording failed" notification. With `MIC_MUTE_GATE=on` the call app's own mute state is not available (it reads "unknown" and the microphone is recorded); the menu's Pause Microphone is the guaranteed way.

## Enabling Google Meet (optional)

Google Meet detection is off by default: it needs the broad Chrome automation permission and is the least verified platform.

1. In `config.env` set `ENABLED_PLATFORMS=zoom,teams,meet`.
2. Restart the app (menu Quit, then `open -n ~/Applications/CATE.app`).
3. Run `setup` again and allow the **Chrome automation** prompt (it reads the address and title of Meet tabs; the permission covers Apple Events to the
   whole browser).
4. Do the test of appendix A of [LIVE_TEST.md](LIVE_TEST.md). In particular check that no new session starts after you leave Meet while the tab stays open
   and another Chrome tab plays sound (a known limit).
