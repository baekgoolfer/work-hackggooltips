# The Settings window

Menu-bar icon, **Settings…** (Cmd-,) opens one window with five tabs: **General**, **Claude**, **Transcription**, **Detection**, **Privacy**. It edits
the same `config.env` that you can still edit by hand (every key is explained in [CONFIGURATION.md](CONFIGURATION.md) and
[config/config.env.example](../config/config.env.example)); it never replaces that file, it changes only the lines you touched.

**Status, honestly.** The logic behind the window (what a typed value means, what is written, what is refused, what the Keychain is asked, the privacy
text) lives in plain functions that the self tests check (`make test-swift`, section S-ST-01) together with the Python side
(`pipeline/tests/test_settings_parity.py`). The AppKit layer on top is thin. It was drawn offscreen to look at the layout and its Save, Save key, Check key and restart handlers were driven once,
offscreen, by a throw-away harness with test doubles (the harness is not part of the repository). The changes made after the first review (the restart that waits for a call, the **Check key** lock, the folder status in the
background, the debounce of the typing) were **not** drawn or driven again: they are plain functions with self tests (including a folder checker whose queues the
test runs by hand), and the AppKit code that calls them is a few lines that were only read. Nobody has used the window in a real session yet: the
real Keychain tool, Terminal, the relaunch and the folder chooser were never exercised. Only Zoom has been verified in real
calls; nothing in this window changes that.

## What is stored where

| What | Where | Written by |
|---|---|---|
| The twenty settings below | `~/Library/Application Support/MeetingCapture/config.env` (one line per key; the other lines, comments and unknown keys stay as they are) | this window, or you by hand |
| Anthropic API key | Keychain item, service `CLAUDE_KEY_SERVICE` (default `MeetingCapture Anthropic API key`), account = your login name | this window (**Save key**), or `make set-api-key` in a Terminal |
| API key of CLOVA / of an OpenAI-compatible server | Keychain item, service `MeetingCapture ASR clova` / `MeetingCapture ASR openai-compat`, account `<login name>@<host>:<port>` of the **saved** address | this window, or `mcap asr-engines secret set <engine>` in a Terminal |
| Consent to send speech to a cloud engine | `asr-consent.json` in the support folder | **only** `python -m mcap asr-engines consent <engine>` in a Terminal (you type a sentence). This window shows the state and opens Terminal for you; it never writes the file |
| Google Calendar sign-in (token) | Keychain item `MeetingCapture Google Calendar token` | **only** `python -m mcap gcal auth` in a Terminal. The window shows whether you are signed in, never the account or the token |
| Which call apps are recorded or never recorded | `call-apps.json` in the support folder (mode 0600) | this window, with the same code as the **Call Apps** submenu; applies at once, without **Save** |

Keys are written to the Keychain with the method the Python side uses for its Google token: `/usr/bin/security -i` with the command on its standard input and
the value hex-encoded, so the key is in no command line, no environment variable, no file and no log. The app uses the same service and account strings as
the pipeline, so what the window stores is what Python reads (a test runs the exact command against a fake `security` tool and reads it back with the
pipeline's own code). Nothing about a key is shown except **Stored in Keychain** or **Not stored**: no length, no prefix, no part of the value.
**Not verified:** no test ran against the real macOS Keychain (the tests use fake `security` tools, as everywhere in this repository), and the interactive
mode of `security -i` does not report a failed command, so the window reads the item back once and compares. A Swift `String` cannot be wiped: the key you
typed stays in the process's memory until the memory is reused; the field is emptied right after the call and when the window closes.

## General

| Key | What it is | Applies |
|---|---|---|
| `UI_LANGUAGE` | Language of the app's own texts: `en` or `ko` | after a restart |
| `ARCHIVE_DIR` | Where finished meetings are filed; **Choose…** opens a folder chooser. Under the field the window says whether the folder exists and is writable, will be created (its parent exists) or cannot be used (its parent is missing: a synced folder whose app is not running; meetings then stay in staging). The file system is asked in the background, 0.4 s after you stop typing (and when the window opens): a stale network mount cannot freeze the window, and a half-typed path under Documents or a removable volume does not raise a macOS file-access prompt | after a restart (the pipeline: the next run) |
| `SELF_NAME` | Label of your microphone track in transcripts and notes | after a restart (the pipeline: the next run) |

## Claude

| Key | What it is | Applies |
|---|---|---|
| `CLAUDE_AUTH` | `api` (an Anthropic Console API key from the Keychain, billed per token; the default) or `subscription` (your own claude.ai login: check Anthropic's terms first, see the README) | next processing run |
| `NOTE_MODEL` | Model alias of the meeting note (`opus`, `sonnet`, a model id) | next processing run |
| `CLAUDE_DAILY_BUDGET_USD` | api mode: the later Claude stages of a day stop when the day's cost reaches this (`0` = off) | next processing run |
| `CLAUDE_MEETING_BUDGET_USD` | api mode: the limit of one processing run (`0` = off) | next processing run |

The **API key** row has **Save key**, **Check key** and **Remove key**. The field is a secure field and is never filled in from the Keychain. **Check key** runs
`python -m mcap api-key check` (one tiny paid call, about a tenth of a cent, with the clean environment and the 30 second limit every pipeline job gets) and
shows the verdict, the model and the cost, never the reply. A key that does not start with `sk-ant-`, or that contains a blank, a line break or a
non-ASCII character, is refused before anything is run. **Check key is off while the organisation policy keeps the Claude lane closed** (the row says why):
it is a real call to Anthropic, `api-key check` is an explicit command that the pipeline does not gate by the lanes, and the Privacy tab says that no
transcript text goes to Claude on such a Mac.

## Transcription

| Key | What it is | Applies |
|---|---|---|
| `ASR_ENGINE` | `whisper` (on this Mac, the default), `clova`, `openai-compat`, `azure`, `remote` or `auto` | after a restart (the pipeline: the next run) |
| `ASR_STRATEGY` | `dual` (every chunk decoded twice by the local model and merged; the default) or `single` | next processing run |
| `ASR_CLOVA_INVOKE_URL` | The https invoke URL of your own CLOVA Speech domain (a NAVER Cloud host). Its host and port are what your consent and your API key are bound to | next processing run |
| `ASR_OPENAI_COMPAT_URL` | Base https address of a server that implements `POST <base>/audio/transcriptions`. **You** decide who runs it | next processing run |
| `ASR_OPENAI_COMPAT_MODEL` | The `model` field of that request: one printable token without blanks, up to 100 characters, as the pipeline accepts it (`whisper-1`, `Systran/faster-whisper-large-v3`, `openai/whisper-large-v3`). A quote at either end, a leading `#` and a `KEY=VALUE` look-alike are refused as well: the `config.env` writer cannot store them | next processing run |

A cloud engine shows its **consent state**, read through `python -m mcap asr-engines list --json` (valid until a date, no consent, expired, the address
changed since, ...). **Open Terminal and grant consent** writes a small `.command` file (mode 0700, in a private temporary folder, it deletes itself) that
runs exactly `python -m mcap asr-engines consent <engine>` from the pipeline folder and opens it in Terminal; the sentence you type there is the
consent. There is no way to give it from the window, by design. After you are done, the window refreshes when you come back to it (or press **Refresh**).

The API-key rows of CLOVA and of the OpenAI-compatible server work on the **saved** address: the Keychain item is bound to its host and port (the same reading
as the pipeline's `asr_providers.split_base`, checked against a shared corpus of addresses), so while the address field has unsaved edits the key buttons
are off, and a key cannot be stored for an engine without a valid saved address. The key of the OpenAI-compatible server is optional (a server without a
key is a legitimate setup). The address of the company server (`ASR_REMOTE_URL`) and Azure are not edited here; `remote` is set up from the menu item
**Connect to Company Server…**.

## Detection

| Key | What it is | Applies |
|---|---|---|
| `ENABLED_PLATFORMS` | Check boxes for Zoom, Microsoft Teams, Google Meet (Meet is off by default and needs the Chrome Automation permission). **None checked is written as an empty value and means no automatic detection** | after a restart |
| `CALL_DETECT` | `known` (the built-in table of call apps plus your list; the default), `generic` (also **guesses** any app that holds the microphone and plays sound; opt-in) or `off` | after a restart |
| `CALL_BROWSER_URLS` | Also read the address of Chrome tabs for meeting pages of Whereby, Jitsi, Webex web, Teams web and Zoom web (needs the Chrome Automation permission) | after a restart |
| `EXTRA_MEETING_APPS` | More call apps: bundle ids separated by commas, each `id` or `id=Name`. Checked with the same parser the app uses; an entry it would drop (a browser, Zoom, a wrong id) refuses the whole value | after a restart |
| `OFFLINE_AUTOSTART` | `auto`: start a recording from an in-person event of your Google Calendar, with nobody pressing a button. **It records whoever is in the room**; read [CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md) first | after a restart |

Below `EXTRA_MEETING_APPS` the **call apps list** is the content of the **Call Apps** submenu of the menu-bar menu (the same rows, titles and decisions):
a check mark means the app is recorded when it looks like a call, no mark means never record. A click is saved at once in `call-apps.json`. A line says when
the file cannot be read (then no call of another app is recorded until it is fixed) or when `CALL_DETECT` is off (the choices are kept but not used).

Under `OFFLINE_AUTOSTART` a line shows the **Google Calendar** state from `python -m mcap gcal status` (signed in, not signed in, the OAuth client file
missing, blocked by the organisation policy), without the account or any path. **Open Terminal and sign in to Google** opens Terminal with
`python -m mcap gcal auth`, as for the consent. The Google Cloud OAuth client you need once is described in [CALENDAR_AUTOSTART.md](CALENDAR_AUTOSTART.md).

## Privacy

| Key | What it is | Applies |
|---|---|---|
| `LOCAL_ONLY_DEFAULT` | Every new recording starts Local-Only: no note (Claude), calendar lookup, archive upload or cloud speech engine for it. A single meeting can still be changed in the menu | after a restart (the pipeline: the next run) |
| `NOTIFY_RECORDING` | A notification when a recording starts and ends | after a restart |
| `LOG_CONTENT` | Logs may contain meeting titles and short transcript snippets (off: only lengths and short hashes) | after a restart (the pipeline: the next run) |

The read-only box **What leaves this Mac** states in plain words, in English or Korean, what leaves the Mac **under the saved settings** (not under
unsaved edits): speech recognition (only to a cloud engine that is selected, that the policy lets be used, that has a valid consent **and** whose API key is
stored; otherwise this Mac transcribes locally), transcript text (to Claude for the note, unless Local-Only or the organisation policy closes that lane), the
calendar (Google, read-only, when auto-start is on; the claude.ai connector lookup while `CALENDAR_LOOKUP` is on) and the archive folder (a folder that looks
synced, for example Google Drive for desktop, is named as a way for the audio files to leave). The wording follows [PRIVACY_LANES.md](PRIVACY_LANES.md). It does **not** say that audio never leaves
the Mac, because with a synced archive folder it can.

**The decisions are the menu's.** What is allowed (Local-Only, the policy lanes, the engines a policy lists in `asr.allowed_engines`, a company Mac that has
no `ARCHIVE_DIR` of its own, the archive roots) comes from `EffectiveLanes` in `Policy.swift`, the code behind the menu lines and the notifications, so the box
cannot say that audio or the archive leaves where that code says it stays (a self test compares the two over a grid of policies, engines, consents and folders).
When a policy does not open the archive upload for the folder, the box says the meetings stay on this Mac.

**The vocabulary.** With `ASR_SEND_VOCAB` on (the default; an unclear value reads as off) and the policy allowing it (`asr.send_vocab.server` for the company
server, `.cloud` for Azure and CLOVA; a company's cloud default is off), the terms of your `vocabulary.txt` go along with the speech to CLOVA, Azure and the
company server: the box says "and the terms of your vocabulary list" (the list can hold partner or competitor names). `openai-compat` sends no terms and the
box does not name any. The consent and key states come from
the pipeline command above (`asr-engines list --json`: consent, and the credential row, `missing` = no key stored, nothing can be sent); when they cannot be
read the box says so and claims no upload.

## Saving

- **Save** writes only the controls you touched. A control that says what the file already says changes nothing, and a stored value that the app does not
  understand (a typo) stays as it is until you pick a value for that control. The file is read again at the moment you press Save, so a line you edited by hand
  in the meantime stays.
- **A stored text that is not understood** (a typo) is flagged under its control, and the control shows **what the code really reads**, which is not always the
  default: `LOCAL_ONLY_DEFAULT` unclear reads as `1` and `LOG_CONTENT` unclear as `0` (both fail closed), `CLAUDE_AUTH` unclear as `subscription` while the
  pipeline makes **no Claude call** until it is fixed, `ASR_STRATEGY` unclear as `single`, `CALL_DETECT` unclear as `known` (also on a managed Mac), and a budget
  that is no number (`$5`) stops the pipeline with an error (`bad value`) until it is fixed. A budget of `0` or below, or `nan`, reads as no limit. Every rule is checked in
  the self test against the real parser (`PrivacySettings`, `AppConfig`, `CallDetectSettings`) and, for the pipeline, against `config.py` through the shared corpus.
- Every value is checked with the rules the parsers use (`Config.swift`, `Policy.swift`, `CallApps.swift`, `pipeline/mcap/config.py`): a text the parser would
  reject, clamp or read as something else is refused with a message and **nothing at all is written**. Refused as well: a line break or another control
  character, a blank at either end, ` #` or a leading `#` (it would turn the rest into a comment), a quote at either end (the two parsers strip quotes
  differently), a value that looks like another `KEY=VALUE` line, a key name that is not a plain upper-case key, a number that is not a plain decimal
  (`5` or `2.5`), a relative folder, a key the window does not edit (a secret's name, for example).
- The change is made in the text of the file: the edited line keeps its spaces, its quoting style (`"..."`, `'...'`) and its trailing comment; a switch
  keeps its words (`true`/`false` stays `true`/`false`); a key without a line is appended under the comment `# Added by the Settings window`; clearing a text
  field removes the key so that the default applies again. The result is parsed again by the real `parseEnvText` and by a mirror of the pipeline's parser: it
  must hold exactly the intended values and change nothing else, or it is not written.
- The file is written atomically (a temp file next to it, mode 0600, renamed over it). **Before** that a backup of the old file is written next to it as
  `config.env.bak-settings-<yyyyMMdd-HHmmss-SSS>` (mode 0600; the last five are kept, other files are never touched). If any step fails the old file is as it was.
  A `config.env` that is a symbolic link is written through the link; one that is not valid UTF-8, or that uses a lone carriage return or another unusual line
  separator, is not touched at all (the window says so).
- Config keys never hold a secret, so neither do the backups.

**Policy locks.** On a Mac with an organisation policy a control is disabled, with the reason, when the policy enforces that key (`enforced`, the company
baseline included: `LOG_CONTENT`, `NOTIFY_RECORDING`), or for `LOCAL_ONLY_DEFAULT` when the policy fixes Local-Only or makes it the default (the start value
is the policy's default OR your setting, so the file cannot turn it off). A policy `defaults` entry is no lock: it shows until your file says otherwise. On such a
Mac an unset `CALL_DETECT` shows `off`, because that is what the app reads (a mistyped one reads `known`). [POLICY.md](POLICY.md) describes the policy.

**After saving:** the window says **Saved. Restart the app to apply.** (the pipeline reads `config.env` on every run, so a change of only pipeline keys also applies
from the next processing run and the window says so) and offers **Restart now**. Restart starts a helper that waits until the running app has quit, then
opens a new instance of the bundle (`open -n -a`). It is refused while a recording is running, where the button only offers **Restart after the recording**
(it restarts as soon as the recording ends; click again to cancel). It is also held back where a relaunch would **undo something that lives only in the
running app's memory**, because the new process would then record the still-running call again: **Pause Auto Recording** (the button is off and says to resume
first), a call you stopped with **Stop Recording Now** or that the no-speech rule ended while it is still running, and a call that was just detected and is about to
be recorded (the button then offers **Restart after the call**, and an armed restart does not fire while the call lasts). The app tells the window through
`ControllerState.restartHold`. An armed restart is always cancelled by the same button. A copy that does not run from an app bundle (a bare binary) cannot
relaunch itself.

## Menu-bar icons and the app icon

The menu-bar icon follows the state: idle `pencil.and.list.clipboard`, recording a red `pencil.and.scribble` that alternates with `pencil.line` once a second
(not with Reduce Motion on), paused `pause.circle`, automatic detection off `pencil.slash`, a meeting detected the idle symbol, processing `ellipsis.bubble`,
done `checkmark.circle`, error `exclamationmark.triangle`. Every name exists on macOS 14.4 (SF Symbols 5) and every list ends in a symbol of the former set, so an
older macOS shows something. The app icon is a clipboard with written lines and a pen, see [BRANDING.md](BRANDING.md).

## If something is wrong

- **A value is refused:** the message sits under the control and in the status line; fix it or press **Revert**.
- **The window says config.env cannot be used:** the file is not valid UTF-8 or uses an unusual line separator. Edit it by hand; the window edits nothing meanwhile.
- **The consent or Google state says it could not be read:** the pipeline could not be asked (no venv, a runtime that is not trusted on a managed Mac, a timeout).
  Run `python -m mcap asr-engines list` or `python -m mcap gcal status` from the pipeline folder to see why.
- **A key does not save:** the status line says whether the value was refused or the Keychain tool could not be run or did not take the item. Nothing is stored in
  those cases. `python -m mcap api-key status` (Terminal) shows what the Keychain holds, without the value.
- Hand edits of `config.env` keep working; so do the Terminal commands. The window is a convenience on top of them.
