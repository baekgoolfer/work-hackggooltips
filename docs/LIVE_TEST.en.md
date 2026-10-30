# First live session checklist (English)

The automatic tests (`make test`) use no device and no permission. Everything on this page needs a real Mac, a real microphone, the macOS permission prompts and a real call, and it is the only way to know that recording works on your Mac.

The complete checklist, [LIVE_TEST.md](LIVE_TEST.md), is **written in Korean**. It has more tests than this page: notification checks, AirPods and Bluetooth, abnormal situations (quit, `kill -9`, closing the lid, switching devices, revoking a permission), the mute-aware microphone tests and an appendix for Google Meet. **This page is the English version of the minimum you do before you turn on automatic start**, with the same section numbers as the Korean file. Commands and file names are the same in both.

Each step has three parts: the command, what you should see, and what to keep. If what you see differs, **stop there**, collect the files of section 8 and open an issue.

| Section | What | Time |
|---|---|---|
| 0 | What you need, shell variables | 5 min |
| 1 | Check the install (`make doctor`, signature, settings) | 5 min |
| 2 | Grant the permissions in one go (`setup`) | 5 min |
| 3 | Device test `selftest-capture --live` | 10 min |
| 4 | Zoom call alone, then read the result | 20 min plus processing time |
| 5 | Teams call alone | 15 min plus processing time |
| 7 | Turn on the login agent, log out and in | 15 min |
| 8 | What to attach to a bug report | 5 min |

Zoom and Teams detection is verified on one setup only, and Google Meet detection is off by default (`ENABLED_PLATFORMS=zoom,teams`), so the order is Zoom alone, then Teams alone. Closing the laptop lid puts the Mac to sleep: recording and processing stop until it wakes. Do not close the lid during a call or while a meeting is processed.

## 0. What you need

- Two terminal tabs: tab A runs commands, tab B watches the output of `probe --watch`.
- A YouTube video in which one person speaks English for more than five minutes (a talk or an interview). It plays the role of the remote participant. Play it in a separate Chrome window.
- You are alone in the calls (Zoom: New Meeting; Teams: Meet now).
- Audio setup A: the MacBook speakers and the built-in microphone (System Settings, Sound, Input and Output). Do the call tests with setup A. If you use a speakerphone or a headset in real meetings, repeat the short device test (section 3) and a short call with that device too.
- Paste this once into **each** terminal tab. The later commands use the variables.

```bash
APP=~/Applications/CATE.app
SUP="$HOME/Library/Application Support/MeetingCapture"
LOGS=~/Library/Logs/MeetingCapture
PY="$SUP/venv/bin/python"
ARCHIVE="$(sed -n 's/^ARCHIVE_DIR=//p' "$SUP/config.env" | tail -1 | sed "s#^~#$HOME#")"; ARCHIVE="${ARCHIVE:-$HOME/Meetings}"     # where finished meetings go
PROJECT="$(sed -n 's/^PROJECT_DIR=//p' "$SUP/config.env" | tail -1 | sed "s#^~#$HOME#")"; cd "${PROJECT:-.}"     # the root of your clone: make install wrote its path as PROJECT_DIR
```

- Read these sentences aloud during the calls, exactly as written, and compare them with the transcript afterwards. They contain terms from the example vocabulary (`config/vocabulary.txt`) and numbers.

```
(1) 안녕하세요, ExampleCorp의 ExampleScan-CXR 팀입니다. 오늘은 API 연동이랑 KPI 일정에 대해 이야기할게요.
(2) The OKR review with Fabrikam-Health is on March twelfth. The budget is forty thousand dollars, about 3.5 percent over plan.
(3) Fabrikam-Health랑 Example Radiology 쪽 API 문서는 다음 주 목요일까지 검토하기로 했습니다. Contoso-Labs가 KPI 표를 보내 주기로 했고요.
(4) 숫자 확인: 1,234,567달러, 2026년 11월 18일 오후 3시 30분, PO 번호는 555-0100입니다.
(5) ExampleCorp.ai, ExampleScan-CT, Example Radiology, Fabrikam-Health, Contoso-Labs, API, KPI, OKR.
```

  Sentences (1), (3) and (4) are Korean because the app is tested with Korean and English. If you do not speak Korean, read (2) and (5) and say the numbers of (4) in English; the spelling checks in the result table then apply to what you said.
- Note the time (`date +%T`) when you join, mute, unmute and leave. You need it to read the logs.
- Start the app by hand for these tests (`open "$APP"`), **not** through the login agent. The login agent comes last, in section 7.

## 1. Check the install

If you have not installed yet, follow [INSTALL.md](INSTALL.md) first. Then:

```bash
make doctor
codesign -dvvv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature"
grep -E '^(CLAUDE_AUTH|ENABLED_PLATFORMS|LOCAL_ONLY_DEFAULT)' "$SUP/config.env"
~/.local/bin/claude auth status          # only if you want meeting notes
```

**Expect**

- `make doctor` ends with no FAIL: the configuration, the Python environment, the speech model in the cache, the Silero model (when you installed it with `--with-silero`) and a writable `ARCHIVE_DIR`. Read every WARN.
- `codesign`: `Identifier=<bundle id>` (`org.meetingcapture.app` unless you built with your own `MCAP_BUNDLE_ID`), and either `Authority=MeetingCapture Local Signing` (you made the local identity with `scripts/make_signing_identity.sh`) or `Signature=adhoc`. With an ad-hoc signature macOS asks for the permissions again after every new build.
- `ENABLED_PLATFORMS=zoom,teams`, or no line at all (same default).
- `claude auth status` shows `authMethod` `claude.ai` for `CLAUDE_AUTH=subscription`. With `CLAUDE_AUTH=api` the key must be in the Keychain (`make set-api-key`).
- The install did **not** write the login agent: it says "not written: you have not confirmed the live test yet". The app does not start at login before section 7.

**Without Claude**: audio and transcripts do not need it. On a personal install `setup` reports a missing or logged-out `claude` tool as `[WARN]`, not `[FAIL]`, so you can still finish section 7. If you do not want meeting notes at all, set `LOCAL_ONLY_DEFAULT=1` in `config.env`: every new meeting then starts Local-Only (no Claude call, no calendar lookup, no archive upload) and you get audio and transcripts only; a missing API key item is a `[WARN]` too.

**Keep**: the output of `make doctor` and the three `codesign` lines.

## 2. Grant the permissions (`setup`)

Always start it with `open -n`, so that the permission prompts belong to Catch Everything and not to your terminal:

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args setup
```

**Expect**

- Allow every prompt: **Microphone**, **System Audio Recording** (a short beep, and the check waits up to 15 seconds), **Notifications**, and **Google Drive** only if `ARCHIVE_DIR` is inside Drive for desktop.
- **No Chrome automation prompt** while Google Meet detection is off (`permission chrome-automation: skipped`).
- Every line starts with `[ OK ]`. For `[FAIL]` or `[WARN]`, do what the `next:` line below it says and run `setup` **again** (if you clicked Allow on the system audio prompt late, the first run reports silence: run it again).
- System Settings, Privacy & Security: Catch Everything is switched on under Microphone and under Screen & System Audio Recording (system audio only). The same report is in `$LOGS/setup-report.txt`.
- Starting the binary from a terminal prints `refused`: that is the safety check that keeps the prompts off your terminal.

**Keep**: `$LOGS/setup-report.txt`.

## 3. Device test

The app records the two tracks with the real microphone and the system audio tap; it speaks a short sentence through the speakers to fill the remote track. Do not run it during a real meeting, and speak while it runs.

```bash
open -n -W -a "$APP" --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out ~/mcap-selftest
```

**Expect**: `"verdict": "PASS"` at the end, `remote_peak_window_db` above -50, `remote_seconds` and `mic_seconds` about 12.

If the remote track is silent (`verdict: FAIL`), try a fixed tap strategy and send which value gave PASS (`--env` goes **before** `--args`):

```bash
open -n -W -a "$APP" --env MC_TAP_HOST=tap-only --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 30 --out ~/mcap-selftest
```

The values are `builtin`, `default` and `tap-only`. For a Bluetooth headset or a speakerphone, set it as input and output and run the test again with `--seconds 30`; the log lines are `grep -E "tap host strategy|tap format|first IO callback" "$LOGS/app.log" | tail`. The Korean file has a longer AirPods section (3.1).

**Keep**: the JSON output.

## 4. Zoom call alone

Start the watcher in tab B, then start the app by hand in tab A (the menu bar shows `Idle`):

```bash
mkdir -p ~/mcap-feedback; : > ~/mcap-feedback/probe-zoom.txt
open -n -W -a "$APP" --stdout ~/mcap-feedback/probe-zoom.txt --stderr ~/mcap-feedback/probe-zoom.txt --args probe --watch --interval 1 --minutes 30 &
tail -f ~/mcap-feedback/probe-zoom.txt          # tab B
open "$APP"                                      # tab A
```

The test takes about 8 minutes:

| When | What you do | What you should see |
|---|---|---|
| T0 | Zoom open, no call, 30 seconds | probe shows `udp 0` and `inCall=no`; nothing is recorded |
| T1 | **New Meeting**, join with computer audio | about 8 seconds later a red dot and `Recording mm:ss` in the menu bar; probe shows `udp >= 1`; `app.log` has `detect: zoom inCall false->true` |
| T1 + 30 s | read sentences (1) and (2); YouTube still off | the baseline of your own words |
| T2 | start the YouTube video; **stay silent for 30 seconds** | later, the remote speech must not appear as text in your own track (echo removal) |
| T2 + 30 s | read sentence (3) while the video plays | later, all of it stays under your `SELF_NAME` label (echo removal must not delete your speech) |
| T3 | **mute in Zoom for 60 seconds**, read sentence (4), unmute | recording continues; your microphone track is still recorded while you are muted (default `MIC_MUTE_GATE=off`) |
| T4 | stop YouTube, read sentence (5), stay silent for 30 seconds | still `Recording` |
| T6 | **Leave**, then End Meeting; note the time | recording ends about 32 seconds later (Zoom has a grace time of at least 30 seconds); `app.log` has `stop (meeting-ended)` |
| T7 | Zoom, Settings, Audio, **Test Mic** for 30 seconds (no call) | a known false-positive spot: if a session starts, stop it with `Stop Recording Now`; with no speech it must be discarded to `sessions/_discarded` and no note must appear |

### Reading the result (Zoom and Teams)

Processing starts about 30 seconds after the call ends. The menu shows `Transcribing`, `Creating note`, `Done`, and macOS shows a notification that the meeting note is ready (clicking it opens the meeting folder). With `LOCAL_ONLY_DEFAULT=1` there is no note step, and the finished meeting is kept in `LOCAL_ARCHIVE_DIR` (default `$SUP/local-meetings`) instead of `ARCHIVE_DIR`: use that folder for `ARCHIVE` in the commands below.

```bash
LAST="$(ls -dt "$ARCHIVE"/*/*/ | head -1)"; echo "$LAST"; ls -la "$LAST"
PLOG="$(ls -t "$LOGS"/pipeline-*.log | head -1)"; tail -40 "$PLOG"
cat "$LAST/session.json"
```

**Expect** the files `transcript.md`, `transcript.json`, `audio.m4a`, `mic.m4a`, `remote.m4a` and `session.json`; when Claude is used also `transcript.cleaned.md`, `meeting-note.md` and, from the verification pass, `meeting-note.draft.md`. The last log line is `DONE: <folder>`.

| Check | Where | You should see |
|---|---|---|
| The session | `session.json` | `end_reason: "meeting-ended"`, tracks `remote` and `mic`, `platform: zoom` (`teams` for Teams); no `remote_silent_suspected: true` while YouTube was playing |
| Your words | `SELF_NAME` blocks of `transcript.md` (default label `Me`) | sentences (1) to (5) almost as read; check the spelling of the terms and the numbers (3.5, 1,234,567, the date, 555-0100) and write down the errors |
| The other side | what YouTube said | under the `Remote` label |
| Echo | the 30 seconds at T2 in your own lines | no line in your label that repeats the video |
| Your speech kept | sentence (3) | fully under your label; **if it was removed, report that first** |
| The raw transcript | `transcript.md` | never edited by an LLM; `diff transcript.md transcript.cleaned.md` shows only terms and transliterations changed, numbers and dates identical |
| The note | `meeting-note.md` | seven headings; no invented attendees, decisions or owners; numbers unchanged |
| Cost (API mode) | `cd pipeline && "$PY" -m mcap usage --days 1` | one line per Claude call with `cost_usd`; compare the sum with the Console usage page |

**Keep**: yes or no for each row, the wrong terms and numbers, the times of joining, muting, leaving and `Done`, and the times at which `udp` and `in` went back to 0 in the probe file.

## 5. Teams call alone

Start `probe --watch` as in section 4 (file `probe-teams.txt`, `--minutes 25`) and keep the app running. In Teams choose **Meet now** (alone). About 6 minutes:

| When | What you do | What you should see |
|---|---|---|
| T0 | stay in the pre-join screen with the microphone meter for 10 seconds | not recording yet |
| T1 | **join** with computer audio, read sentences (1) and (2) | about 8 seconds later `Recording`; write down which process holds the audio (the app or a `.helper`) |
| T2 | YouTube for 30 seconds, read sentence (3) | the echo and speech-kept checks of section 4 |
| T3 | **mute for 60 seconds**, read sentence (4), unmute | **the main Teams risk:** if Teams drops the microphone input while you are muted, the recording could end in the middle of the call after the grace time. It must stay `Recording` for the whole minute. If it changes to processing, report the time at once |
| T4 | read sentence (5), leave; note the time | the recording ends about 32 seconds after leaving |

Read the result as in section 4 (`platform: teams`). Optional, with a second person: reject an incoming call that only rings; no session must start.

**Keep**: `probe-teams.txt`, the part of `app.log` around T3, whether the recording stayed on while muted (yes or no, with the time), and the table of section 4.

## 7. Turn on the login agent

Turn it on last. `scripts/install.sh` and `scripts/make_launchagent.sh` neither write nor load the agent before you confirm. Quit the hand-started app from its menu, then:

```bash
make confirm-live-tested                       # checks that the setup report has no [FAIL], shows the recording legal notice and asks you to type yes and then 'confirmed'
scripts/make_launchagent.sh --dry-run --load   # prints the plist and the launchctl command only
scripts/make_launchagent.sh --load
pgrep -fl "CATE.app/Contents/MacOS/CATE"
```

**Expect**

- `make confirm-live-tested` needs a terminal and your typed words (yes for the legal notice, then `confirmed`), and is only meaningful after `setup` (section 2) and the device test (section 3). `--load` without it stops with "live test not confirmed".
- Within a few seconds the menu bar shows the icon and `Idle`. If macOS says that a background item was added, switch Catch Everything on in System Settings, General, Login Items.
- `pkill -9 -fx "$APP/Contents/MacOS/CATE"` brings the app back by itself within about 30 seconds. Quit from the menu does not (that is intended).
- Log out and log in again without opening a terminal: the icon is there. Do a Zoom call alone for 2 minutes and read the result as in section 4. If you use Claude, `claude attempt 1` in the pipeline log must not say "Not logged in" (the login agent must see your `claude` login), and with `CLAUDE_AUTH=api` no Keychain dialog may appear; if one does, do not click Always Allow, report it first.
- Run `make doctor` once more in a terminal and compare.

**Keep**: the output of `confirm-live-tested` and `--load`, the first 30 lines of `app.log` after the login, and how long the `kill -9` restart took.

## 8. What to attach to a bug report

**Do not upload audio files.** Transcripts and notes contain what people said. The folder of a test call (you alone, plus YouTube) may be attached; **never attach the folder of a real meeting** (hide names and amounts and send only the lines that matter). Logs can contain meeting titles and transcript fragments: set `LOG_CONTENT=0` and reproduce the problem, or cut the text out, before you attach them.

The script in section 8 of [LIVE_TEST.md](LIVE_TEST.md) collects the right files into one folder (`~/mcap-feedback/<date>`): `app.log` (meeting links are masked), `setup-report.txt`, the last pipeline logs, the probe files, and per test call `session.json`, `state.json`, the transcript, the note and a transcript file with statistics but no text. Its comments are Korean; the commands and file names are not. If you stopped early, add the number of the section, the last command and its full output, and 30 lines of `app.log` around that time.
