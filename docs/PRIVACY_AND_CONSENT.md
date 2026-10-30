# Privacy and consent

This page answers two questions: what does Catch Everything do with other people's voices and words, and what is your responsibility when you use it. It is written for the personal install. The experimental organisation mode adds policy files and more switches, described in [PRIVACY_LANES.md](PRIVACY_LANES.md) and [POLICY.md](POLICY.md).

**This is general information, not legal advice. It is deliberately jurisdiction-neutral. Ask a lawyer about the rules that apply to you.**

## 1. The short version

- The app records every other participant (the audio your Mac plays) and you (the microphone), **including while you are muted in the meeting app**. Nothing is announced to the other participants by the app, and the meeting platform shows no recording banner because the app does not use the platform's recording function.
- Speech recognition runs on your Mac. Audio is never sent to Claude.
- Text does leave your Mac: the transcript, the meeting title, your vocabulary list and (if enabled) calendar details go to Anthropic to write the notes.
- Audio leaves your Mac in one situation you may not think about: when the archive folder is a cloud-sync folder such as Google Drive, the finished audio files are uploaded with the rest of the meeting folder.
- You decide whether a recording is allowed and you carry the consequences. Where in doubt, tell the participants or use the local-only switch (section 4) or do not record.
- The install (`scripts/install.sh`) and the step that unlocks the login agent (`make confirm-live-tested`) print the legal notice of the README and ask you to type `yes`. A run without a terminal needs the explicit option `--accept-legal-notice`: the notice is never accepted for you silently.

## 2. What is recorded

| What | Detail |
|---|---|
| System audio | everything your Mac plays while a recording runs: all remote participants, and with `SYSTEM_AUDIO_MODE=global` (the default) also music and alert sounds. `SYSTEM_AUDIO_MODE=app` restricts it to the meeting app. |
| Microphone | your voice and everything the microphone hears, also while you are muted in Zoom or Teams, and everybody who is in the room with you |
| Not recorded | no video, no screen content, no chat |
| Files | two WAV tracks of 48 kHz mono while the meeting runs (deleted after processing), then `.m4a` files, a raw transcript, a cleaned transcript, a note, and small JSON files (`session.json`, `transcript.json`, and `calendar.json` if the calendar lookup found an event) |

A false detection can record a call that is not a meeting. A recording with less than about 20 seconds of speech is discarded (kept for 7 days in a `_discarded` staging folder, then deleted). Automatic recordings that are digital silence on both tracks end by themselves after `NO_SPEECH_STOP_MINUTES`.

**Calls of other apps.** Besides Zoom and Teams (and Google Meet when you turn it on) the app records the calls of a built-in table of apps by default (`CALL_DETECT=known`): Slack huddles, Webex, Discord, FaceTime, Skype, KakaoTalk, WhatsApp and a few more. That includes **personal messengers**: a call you place in one of them while the app runs is recorded like a work call (the microphone and, in the default global mode, everything the Mac plays), and it goes through the normal pipeline (the transcript text goes to Claude unless the meeting is local-only). The start notification says so (`NOTIFY_RECORDING`), the menu-bar icon shows it, and the menu item **Never record `<App>`** and the **Call Apps** submenu (it lists every app of the table before its first call) stop it for one app; `CALL_DETECT=off` switches all of it off. **Guessing is opt-in:** `CALL_DETECT=generic` also records any other GUI app that holds the microphone and plays sound for about 45 seconds (a game with voice chat, an audio tool the deny list does not know). Such a recording posts a notification that names the app even when `NOTIFY_RECORDING=0`, and the menu-bar icon can be hidden by the notch or a menu-bar manager, so a notification that is switched off in macOS (Focus mode, no permission) means you may not notice it. Your choices are kept in `call-apps.json` (bundle ids, names and the decision; no titles, no content) and the list fails closed: while that file cannot be read, no call of another app is recorded. Only Zoom has been verified in real calls.

## 3. What leaves your Mac, and when

The paths out of your Mac are called lanes. There are five. This is the default personal setup:

| Lane | What leaves | When it runs | How to switch it off |
|---|---|---|---|
| **Speech recognition** | nothing: the Whisper model runs locally. An external engine can only be used if you set `ASR_ENGINE` or `ASR_FALLBACK` to one and typed a consent with `mcap asr-engines consent`; in organisation mode a policy must allow it too. The external engines are a company server, Azure Speech, NAVER CLOVA Speech (`clova`) and an OpenAI-style server at an address **you** choose (`openai-compat`: the project cannot tell who runs that host or where it processes the audio). Then speech is sent, and it contains the remote participants' voices: chunks of up to 28 s, or for CLOVA and the OpenAI-style server blocks of speech (pauses cut out, 16 kHz mono WAV, up to `ASR_CLOUD_BLOCK_SECONDS`). The same request carries the API key you stored for that host, the model name for the OpenAI-style server and, for CLOVA, the terms of your vocabulary list as `boostings` while `ASR_SEND_VOCAB` is on and the policy allows it. Never a title, a session id or the attendees. | never in the quick start | leave `ASR_ENGINE` at its default (`whisper`); `ASR_SEND_VOCAB=0` keeps the vocabulary at home |
| **Claude** (cleanup, note, verification) | transcript text, vocabulary list, title hint, and calendar attendees if the lookup is on. Sent to Anthropic through the `claude` tool with your API key or your login. Never audio. | for every meeting that is not local-only, up to `MAX_CLAUDE_CALLS_PER_MEETING` calls | local-only meeting; or turn the passes off (`TRANSCRIPT_CLEANUP=0`, `NOTE_VERIFY=0`); there is no note without the note step |
| **Calendar lookup** | a request for the events around the recording start (plus or minus 45 minutes); the event title and attendee names and e-mail addresses travel through your claude.ai login's Google Calendar connector into a Claude session. The matching event is saved as `calendar.json` in the meeting folder. | `CALENDAR_LOOKUP=auto` looks the event up whenever your claude.ai login has the Google Calendar connector (it is skipped quietly otherwise); check the value in your `config.env`. It uses the subscription login even in API key mode. | `CALENDAR_LOOKUP=0` |
| **Archive folder** | the whole meeting folder: audio of both sides, transcripts, note, JSON files. If the folder is synced by Google Drive for desktop (or iCloud, Dropbox and so on) the provider receives it, and so does everybody who has access to that folder, workspace administrators included. | every meeting that is not local-only | local-only meeting; point `ARCHIVE_DIR` at a folder that is not synced; `AUDIO_RETENTION_DAYS=N` removes the audio after N days |
| **Local files and logs** | nothing leaves; the data stays on this Mac: staging recordings (deleted after publishing), `app.log` and `pipeline-<id>.log` (meeting titles and transcript snippets of up to 60 characters unless `LOG_CONTENT=0`), `usage.jsonl` (one line per Claude call with stage, model, duration and cost, no text) | always | `LOG_CONTENT=0`; `LOG_RETENTION_DAYS=N` |

Besides the lanes:

- **Google Calendar read access (calendar autostart, opt-in, off by default).** With `OFFLINE_AUTOSTART=auto` the app lets `python -m mcap gcal upcoming` read the events of your primary Google Calendar around the current time (title, times, location, your response, the number of other attendees, whether there is a conference link) so that it can start a recording for an in-person conversation by itself. The access is read-only (`calendar.readonly`), uses your own Google Cloud OAuth client and sign-in, keeps its token only in the Keychain, and talks only to Google; nothing from it is sent to Anthropic or anyone else, and nothing is written to your calendar. The `calendar` lane of an organisation policy closes it. **The recording it starts is a recording of the people in the room, started without a button press, and the consent rules of section 6 apply to it in full.** Setup, warning and revocation: [CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md).
- **Downloads.** The install fetches Python packages from PyPI, the speech model from Hugging Face and the Silero voice-activity model from GitHub. Nothing about your meetings is part of those requests.
- **Telemetry.** The app has none of its own. Hugging Face telemetry and onnxruntime telemetry are switched off by the app and the `mcap` command. Claude Code has its own settings for analytics, and this project does not change them.
- **Backups.** The staging folder and the local archive are excluded from Time Machine backups (`tmutil addexclusion`). Your archive folder is not: it is wherever you put it.
- **Third parties see what you send them.** Anthropic's terms for your account type apply (check retention and use of data, and whether you need a business associate agreement for health data). Google's terms apply to a Drive folder.

## 4. The local-only switch

A **local-only meeting** is transcribed on your Mac and skips every lane: no external speech engine, no Claude (so no cleanup, no note, no verification), no calendar lookup and no upload to the archive folder. The meeting is kept in `LOCAL_ARCHIVE_DIR` (default: a `local-meetings` folder inside the app's support directory) with its transcript. The transcript header says `Privacy: local-only`, and `state.json` records which lanes were skipped.

- One meeting: the **Local-Only Meeting** item in the menu-bar menu. You can switch it on while the meeting is being recorded and afterwards until the recording has been published. You can switch it off again only while recording or before processing has started.
- Every new recording: `LOCAL_ONLY_DEFAULT=1` in `config.env` (an unrecognised value is read as `1`).

Local-only does not legalise a recording and does not hide the recording from the participants. It limits where the data goes afterwards.

## 5. Keeping and deleting data

| Goal | How |
|---|---|
| Delete one meeting for good (staging, local archive or archive folder) | `cd pipeline && "$HOME/Library/Application Support/MeetingCapture/venv/bin/python" -m mcap forget <folder>` asks first, or add `--yes`. It refuses while the meeting is being recorded or processed. If the archive folder is a sync folder, the deletion syncs; the provider may keep deleted files in its trash for a while. |
| Delete audio automatically | `AUDIO_RETENTION_DAYS=N` removes archived `.m4a` files older than N days (transcripts and notes stay). `mcap prune-audio --dry-run` shows what it would delete. |
| Other retention | `LOCAL_ARCHIVE_RETENTION_DAYS`, `STAGING_FAILED_RETENTION_DAYS`, `LOG_RETENTION_DAYS` (all default to keeping everything; see `config/config.env.example`) |
| Remove everything the app keeps | `scripts/uninstall.sh --purge` deletes the support folder and logs. Your archive folder is never touched by the scripts. |
| Share a log or a check report | set `LOG_CONTENT=0` first, and use `mcap doctor --share`, which replaces your home folder and e-mail addresses. Never attach recordings, transcripts or notes to a public issue. |

Anything already uploaded to Anthropic or to a sync provider is outside this project's control.

## 6. Consent and the law

The recording of conversations is regulated in most places, and the rules differ from place to place, from meeting to meeting and from participant to participant. Things that can matter:

- whether one party's consent is enough or everybody's is needed, and where each participant is located (in a call, several sets of rules can apply at once);
- employment and workplace rules, contracts and non-disclosure agreements, and the terms of the meeting platform;
- data-protection law (for example the GDPR) if the recording, transcript or note identifies a person: you may need a legal basis, a notice to the people concerned, a retention limit and a way to answer access and deletion requests;
- stricter rules for health information, children, privileged or other sensitive conversations;
- rules for sending such data to a service provider in another country (Anthropic, a sync provider).

Catch Everything has no consent screen, announcement or indicator for the other participants. Practical habits that help in any jurisdiction:

1. Find out which rules apply before you record, not afterwards. When in doubt, ask the other participants or a lawyer.
2. Tell people at the start, in a way they can answer, and record only if they agree. If someone objects, stop and delete (`mcap forget`). A sentence that is accurate for this tool: "I am recording the audio of this call and creating a transcript and notes with software on my computer. The transcript text is sent to an AI service, Anthropic's Claude, to write the notes. Please tell me now if you do not agree." Adapt it; it is an example, not a legal formula.
3. For sensitive meetings use the local-only switch, or do not record.
4. Do not record meetings with regulated or confidential content unless your agreements and policies explicitly allow it, including the transcript going to Anthropic.
5. Decide who may open the archive folder. Keep only what you need and delete the rest.
6. Never use the tool for covert recording.

## 7. No warranty

The software is provided as is, without warranty of any kind, and the authors accept no liability for how it is used (Apache License 2.0, sections 7 and 8, see [LICENSE](../LICENSE)). Nothing on this page creates a legal relationship or replaces advice from a lawyer who knows your situation.
