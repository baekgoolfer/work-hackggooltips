# Meeting detection (Zoom / Teams / Meet / other calls): final formulas, thresholds, verification status, live-test checklist

Source files: `app/Sources/{AudioProcessMonitor,NetworkProbe,ChromeTabs,Detector,DetectionStateMachine}.swift`, plus
`ProbeCommand.swift` (`probe`), `DetectorSelfTest.swift` (`selftest-detector`) and, for the Zoom evidence tiers (section 3),
`Config.swift` (`ZoomTierSettings`) and `SessionController.swift` (notification gating). Calls of other apps (section 3b) live in
`CallApps.swift` and `Config.swift` (`CallDetectSettings`).
Spec: `SPEC.md` section 5 and 13.1 (13.1 wins), 14.4 (`LaunchGuard`) and 15 (Meet off by default).

**How the signals are read.** Detection uses only public macOS interfaces on the user's own Mac: the Core Audio process objects (which process has an
audio input or output running), libproc socket counts of a process, and the address and title of Chrome tabs through Apple Events (only when Meet is
enabled). No code of Zoom, Teams or Chrome was decompiled, modified or loaded, and no vendor SDK is used. The process names and socket counts below
are black-box observations of these public interfaces on one Mac; they can change with any app update, which is why the verification status of each
formula is tagged.

**Google Meet detection is OFF by default (SPEC 15: it needs the broad Chrome automation permission and is the least verified platform).** `ENABLED_PLATFORMS`
defaults to `zoom,teams` (Swift `AppConfig` and `config.env.example`); append `,meet` (`ENABLED_PLATFORMS=zoom,teams,meet`) to turn it
back on. While `meet` is not enabled the detector does not visit the Meet branch at all: no Chrome tab query, no AppleScript, no Chrome
Automation prompt (`setup` skips its Chrome step and says why), and `probe` omits the Meet sections. Everything below that talks
about Meet (formulas, tab chooser, section 5, the L-10..L-18 checks) applies only once it is enabled. The first live tests are
Zoom alone, then Teams alone (`docs/LIVE_TEST.md`).

**Other calls (section 3b).** Beyond Zoom, Teams and Meet the app also records calls of other apps: a table of known call apps (Slack huddles, Webex,
Discord, FaceTime, KakaoTalk, ... personal messengers included; on by default, `CALL_DETECT=known`), the meeting pages of a few sites in Chrome (opt-in), and,
only when you set `CALL_DETECT=generic`, any other GUI app that holds the microphone and plays sound for 45 seconds (a guess; never the default).
`ENABLED_PLATFORMS` is the list of Zoom, Teams and Meet only: `CALL_DETECT` is what limits these calls. Google Meet stays behind `meet` (off by default) in all of this. **Only Zoom has been verified in real
calls. Everything else, Teams and the whole of section 3b included, is implemented from public signals and unit-tested with fakes**; the table in section 3b
says so per platform.

Evidence tags: **[T]** exercised by `selftest-detector` (device-free, virtual clock); **[L]** observed live on the reference Mac
(idle Mac, Zoom running idle, Chrome running, no call); **[R]** from the research notes (measured there); **[?]** not
verified, needs a real call (live-test ID in section 8); **[A]** from the `app.log` of the reference Mac (Zoom signed in and idle all day,
three real meetings, nine false recordings), see section 3 "Evidence tiers".

## 1. Data flow

```
Core Audio process objects ──▶ AudioProcessMonitor ──▶ per-family raw in/out ──▶ HysteresisFlag (smoothing)
libproc (Zoom main pid UDP) ─▶ NetworkProbe ─────────────────────────────────────┤
Chrome tabs (AppleScript) ───▶ ChromeTabs (gate + cache) ─▶ MeetTabChooser ──────┤
                                                                                  ▼
                                      Detector.poll(): one PlatformSignal per enabled platform (inCall, confidence,
                                      evidence, titleHint / meetingURL / meetingKey for Meet)
                                                                                  ▼
                        DetectionStateMachine.step(): debounce -> .start, grace -> .stop, Meet code change -> .split
                                                                                  ▼
                                        SessionController (starts / stops / splits the Recorder)
```
`Detector.poll()` is blocking and never throws. Without tab queries it takes about 3 ms (median) and 4.5 ms (p95) in steady
state on the reference Mac, 110 ms for the very first poll (Core Audio client start-up) [L]. Tab queries add one Apple Event round
trip only while Chrome has audio IO (section 5).

## 2. Signals and what they cost

| Signal | Source | Permission | Notes |
|---|---|---|---|
| per-process `IsRunningInput` / `IsRunningOutput` | `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessProperty*` | none [L][R] | Polled (the property listeners never fire [R]). PID and bundle id cached per object id; flags read only for family members. `IsRunningOutput` means "a stream is open", silence included. |
| UDP socket count of the Zoom main pid | libproc `proc_pidinfo` / `proc_pidfdinfo` | none (same user) [L][T] | Idle = 0 [L]. mDNS (port 5353) is ignored. Never counts helper processes (`ZoomCefHelper` holds unrelated QUIC sockets [R]). Matches `lsof -iUDP -a -p` [R]; read back correctly for a loopback socket in the self test [T]. |
| Chrome tab URLs / titles | `NSAppleScript` `tell application id "com.google.Chrome"` | **Automation** (Chrome) [?] | Only in the signed app, only when Chrome is running and has audio IO and Automation is already granted (section 5). |

Family mapping (`FamilyMatcher`, bundle id prefixes, case-insensitive) [T]:

| Family | Bundle ids | Notes |
|---|---|---|
| meet | any id starting with an entry of `BROWSER_BUNDLE_IDS` (default `com.google.Chrome`) | Chrome's audio IO lives in `com.google.Chrome.helper` (utility process "audio service"), main and video-capture processes have objects too; all are aggregated [L]. |
| zoom | `us.zoom.xos`, `us.zoom.xos.*`, `us.zoom.caphost` | Other `us.zoom.*` apps (Clips, Phone helpers) are not the call. |
| teams | `com.microsoft.teams*` (new `teams2`, classic) | |
| (not a family) | everything else: dictation, voice memos, other call apps, and our own bundle id and its helpers (`AppInfo.bundleID` and `AppInfo.bundleID.…`, matched at a dot, whatever `MCAP_BUNDLE_ID` the build has; always excluded; another app whose id only starts with the same characters is not) | These three families ignore them. Calls of other apps are the job of the call rule (section 3b), which reads the same Core Audio process objects. `probe` lists non-family processes that hold audio IO so surprises are visible. |

## 3. Per-platform formulas (final)

Notation: `in` / `out` = smoothed (stable) family input / output flags, section 4. `tab` = a Chrome tab whose URL is a
meeting code `https://meet.google.com/xxx-xxxx-xxx` (exact host match; `landing`, `new`, `lookup`, `_meet`, home, ... never
count). `Confidence` has only `.high` / `.low` (Types.swift), so the HIGH and MEDIUM tiers below are both `.high` and the tier is
in the evidence (`tier=HIGH|MEDIUM|LOW`).

**Meet** [T]
```
tabs available (Automation granted, query ok):
    inCall = tab && (in || out)                 HIGH   = tab && in && out          (.high)
                                                MEDIUM = tab && (in xor out)       (.high)
    nickname tab (Workspace nickname, not a code):  inCall = in && out              LOW (.low), keyed by the nickname
    no Meet tab at all:                          inCall = false  (voice typing / YouTube / any other Chrome audio)
tabs unavailable (Automation denied or not asked yet, tab queries disabled, Chrome has no entry in BROWSER_BUNDLE_IDS,
                  script error or timeout):
    inCall = in && out                          LOW (.low); never `in` alone; no title, URL or meetingKey
chrome audio idle (no raw or stable IO): inCall = false, Chrome is not touched
```
`meetingKey` = the code (or nickname), `meetingURL` = `https://meet.google.com/<code>` with the query string removed
(no `authuser`/`hs`), `titleHint` = the tab title. With several Meet tabs open the choice is made by tab **identity** (window id +
tab id) with a **sticky** chooser (`MeetTabChooser`, `ChromeTabs.swift`), not by "the newest code wins": Chrome gives no per-tab audio
state, and a newest-code rule let a second tab in a lobby split a running call at once.
- first sight: meeting codes before nicknames, then the active tab of Chrome's front window, then any window's active tab, then window
  order, then tab order (a stale post-call tab can still be picked here; the known limitation in section 9);
- afterwards the chosen tab stays chosen while it is open and the code it carries is what the state machine follows. Only a tab that was
  opened after the choice (or was chosen before) can take over, and only after it has been the **front window's active tab** in
  observations at least the start debounce (`START_DEBOUNCE_SECONDS`, 4 s) apart. A background tab, an old stale tab or a nickname tab
  (against a code tab) never takes over; while such a take-over is being timed the tab list is refreshed at the fast rate;
- when the chosen tab closes, a tab with the SAME code wins (closing a stale duplicate cannot change the code), otherwise first sight runs
  again; the choice is forgotten once Chrome has had no audio for about a grace period (the session is over).
Back-to-back meetings therefore split only when the next meeting's tab is brought to the front, after the Meet grace.

**Zoom** [T]
```
inCall = udp || input        udp   = sockets(Zoom MAIN pid, `us.zoom.xos`) >= 1, stable
                             input = IsRunningInput of us.zoom.xos / us.zoom.caphost, stable
output alone never counts (chimes, webinar audio).   Evidence says `via=udp`, `via=udp+input` or `via=input`.
```
The main pid comes from the Core Audio process object of `us.zoom.xos`; if Zoom has none, `NSRunningApplication` is the fallback
(cached 10 s) [T]. The window title, `caphost` presence and Zoom logs are not signals (SPEC 13.1).

**Evidence tiers (Zoom only; `Detector.classifyZoom`, `DetectionStateMachine`)** [T][A]. `inCall` above says "this might be a call"; the tier says
how far that can be trusted on its own. Why: a signed-in, idle Zoom 7.0.6 opens 4 UDP sockets on its main pid for 4-6 s about every 2 minutes
(`zoom-audio in=0 out=0 raw=0/0 io=-; udp main-pid=787 sockets=4 stable=1; via=udp`, gone 4 s later with `sockets=0`; seen at 17:09:59, 17:13:59,
17:15:59, 17:21:59, 17:42:07, 18:42:07, 19:00:08 ...). That is as long as the start debounce, so on some days it started a recording (nine of 30-34 s
between 17:50 and 18:46: folder, sleep prevention, start/stop notices, no meeting at all). Real meetings look different: `sockets=7` (and `in=1` when
Zoom opens the mic), `sockets>=3` for the whole call, `sockets=0` when it ends.

| Tier | Evidence (stable flags, main pid sockets `n`) | What the state machine does |
|---|---|---|
| **STRONG** | `n >= ZOOM_STRONG_SOCKETS` (6), **or** Zoom input running (`in=1`), **or** Zoom output running with `n >= 3` | today's rules: recording starts after `START_DEBOUNCE_SECONDS` (4) of inCall |
| **WEAK** | `1 <= n < 6`, no input, no output IO (the flicker signature; also the smoothing hold-over poll with `n = 0`) | counts as a meeting only after it has lasted `ZOOM_WEAK_DEBOUNCE_SECONDS` (15) |

```
The evidence entries are unchanged; the tier is one more, only while Zoom shows sockets or input (entries joined with "; " in app.log):
  the observed idle flicker : zoom-audio in=0 out=0 raw=0/0 io=-; udp main-pid=787 sockets=4 stable=1; via=udp; tier=weak (sockets=4<6, no input, no output)
  the observed real join    : zoom-audio in=0 out=0 raw=1/1 io=787:in+out; udp main-pid=787 sockets=7 stable=1; via=udp; tier=strong (sockets=7>=6)
  join with the mic open    : ...; via=udp+input; tier=strong (sockets=7>=6, input)
```
`PlatformSignal` (Types.swift, not ours to extend) has no tier field, so the tier travels in the evidence text: `Detector.evaluateZoom` writes it,
`PlatformSignal.evidenceTier` reads it (`tier=weak` on a Zoom signal is WEAK, anything else, also a missing entry, Teams, Meet and manual, is STRONG;
the self test pins both halves). The stable (smoothed) input / output flags are used, the same `in=` / `out=` the log shows, so a one-poll raw glitch never
upgrades a weak signal.

State machine rules for the tiers [T]:
- **Start**: a candidate (a run of inCall polls) that has seen a STRONG poll starts after `START_DEBOUNCE_SECONDS`, a weak-only one after
  `max(START_DEBOUNCE_SECONDS, ZOOM_WEAK_DEBOUNCE_SECONDS)`, counted from its first inCall poll (the UDP smoothing adds about 2 s: a weak call is
  recorded about 17 s after its first socket; those first seconds are not recorded, accepted for an unusual call with few sockets and no audio IO). A weak
  candidate is not "meeting detected" in the menu and logs one line when it ends without a recording (`weak evidence ended after N s ...`).
- **Keep**: a recording is kept alive by every inCall poll of a CONTINUOUS run (no gap longer than the 3 s flicker tolerance) that showed STRONG
  evidence at some point, as today: a call that started strong and shrinks to a few sockets with no audio IO stays recorded. A weak-only run counts once it
  has lasted the weak debounce. So a weak-only run that begins after a gap (a flicker during the grace of a call that ended) does **not** re-arm the grace timer
  and (after the stop) starts nothing unless it lasts 15 s. It does not **end** the session either while it is still on: only a poll WITHOUT a signal ends
  a session once the grace is over (review finding: a Zoom that reconnects inside a real meeting, sockets gone ~26 s as seen live, comes back
  with 1 / 2 / 4 sockets and no audio IO for its first polls; ending the session at the poll that shows the call is back split one meeting into two
  recordings and lost ~15 s of it, and it did so for every gap between ~13 s and the grace). A flicker that is still on when the grace runs out therefore
  delays the stop by its own length (at most the weak debounce), never by a new 30 s.
- **Preference**: with several platforms inCall, STRONG goes before WEAK, then high confidence, then enabled order; a weak-only candidate gives way to a
  STRONG signal of another meeting (a Zoom flicker never delays a real Teams call).
- `ZOOM_WEAK_DEBOUNCE_SECONDS=0` switches all of it off: weak evidence behaves like strong, the behaviour before the tiers. A value below
  `START_DEBOUNCE_SECONDS` waits `START_DEBOUNCE_SECONDS`.
- **Teams is unchanged**: no weak tier. Nothing in the data (no Teams call or idle-socket measurement at all, L-06) or the SPEC supports one, and Teams signals
  read as STRONG. If L-06 shows a Teams idle flicker the same machinery applies: write `tier=` in `evaluateTeams`.

Notifications follow the tier (SessionController): a recording that started on WEAK evidence posts no `녹음 시작` until it is
confirmed (a STRONG poll, or 20 s of uninterrupted inCall after its start), and no `녹음 종료 · 전사 시작` unless it was announced; a normal end with less than 60 s of inCall
holds the end notice until the pipeline has decided, and drops it when the pipeline discards the session (no speech).

**Teams** [T]
```
inCall = input of com.microsoft.teams*, stable          output alone never counts, even when sustained
```
Teams UDP is **not** part of the rule in v1 (deviation from the SPEC wording "UDP as an auxiliary"): the socket shape in a call is
unknown (L-06) and a new Teams (Chromium based) may hold UDP/QUIC sockets while idle, which would record around the clock.
`probe` prints the main process's UDP sockets and the count of connected sockets to relay ports 3478-3481 so L-06 can decide.

Our own app, other apps' microphones and any family process that only plays sound never start or keep a session.

## 3b. Calls of other apps (`CALL_DETECT`, `EXTRA_MEETING_APPS`, `CALL_BROWSER_URLS`)

Platform `call` (`Platform.call`, additive): every call that is not Zoom, Teams or Meet. There is one signal **per app** (`PlatformSignal.meetingKey` = the app's main
bundle id, `appName` = its display name, `callKind` = how it was found), after the signals of the three platforms. The state machine treats them like Teams: start
debounce `START_DEBOUNCE_SECONDS`, grace `max(GRACE_SECONDS, 30)`, never a split. A session follows the signal of **its own app**: another app's call neither keeps
it alive nor ends it, and while a recording runs no other app starts a second one (a different app that is still in its call starts after the stop).
**A call of another app never blocks Zoom, Teams or Meet:** while a call recording runs, a Zoom, Teams or Meet signal that is STRONG with high confidence and has lasted `START_DEBOUNCE_SECONDS`
ends the call recording (kept and queued like any stop) and starts that meeting (`split`); a gap of up to 3 s does not restart that wait, and the idle Zoom flicker (WEAK evidence) never takes a call over.
The other way round nothing is taken over: a running Zoom, Teams or Meet recording keeps its session, and the call app that is on at the same time gets one line in `app.log`
(`detect: call:<id> is in a call while the recording zoom:- runs: one recording at a time`), once per call.

### 3b.1 Every platform: signal, evidence tier, verification status

| Platform | Signal | Evidence tier | Default | Status |
|---|---|---|---|---|
| Zoom | UDP sockets of the main process, or input of `us.zoom.xos` / `us.zoom.caphost` | STRONG (6+ sockets, input, or output with 3+ sockets) / WEAK (1-5 sockets, no audio IO, waits 15 s) | on | **verified in real calls** (reference Mac, Zoom 7.0.6, section 3 and `app.log`) |
| Microsoft Teams | input of `com.microsoft.teams*` | STRONG only | on | **not verified in a real call yet**: implemented from public signals, unit-tested with fakes (idle behaviour was observed, no call) |
| Google Meet | address of a Chrome tab with a meeting code + Chrome input / output; LOW fallback without tab access | HIGH / MEDIUM / LOW | **off** (`meet` in `ENABLED_PLATFORMS`) | not verified: implemented from public signals, unit-tested with fakes |
| Known call apps (3b.2) | input **and** output of the app's processes, smoothed (output 7 s, input 1.5 s); kept while either stays | A: in + out, high confidence | on (`CALL_DETECT` known, the default, or generic) | not verified: implemented from public signals, unit-tested with fakes |
| `EXTRA_MEETING_APPS` apps | the same as a known app, for bundle ids you list | A | none listed | not verified (the rule is the same, the app is yours) |
| Meeting page in Chrome (3b.5) | a tab with a meeting URL of the table **and** Chrome input + output | B: tab + in + out, high confidence | **off** (`CALL_BROWSER_URLS`) | not verified: implemented from public link formats, unit-tested with fakes |
| Generic app (3b.3) | a GUI app, not on the deny list, not denied by you, holding input **and** output together for `CALL_GENERIC_SECONDS` (45) | C: in + out held, **low** confidence | **off**: opt in with `CALL_DETECT=generic` | not verified: a guess by design, unit-tested with fakes |
| Manual | the menu item | n/a | n/a | the user's own action |

Nothing in the rows below Zoom has been observed in a real call by this project. Treat every one of them as "may miss calls, may record a non-call" until you have run the checks of section 10.

### 3b.2 Known apps

A known app counts as in a call when its process **or one of its helper processes** holds the microphone input **and** plays output, both smoothed (`DetectionTuning`, section 4).
Helpers are folded into the main app: a Core Audio bundle id belongs to a known app when it is the id or starts with `<id>.` (`com.tinyspeck.slackmacgap.helper`,
`.helper.Renderer`, `.helper.GPU`, ...); input in one helper and output in another count together as one call. Once started the call is kept while the app holds input **or** output
(an app that closes the microphone on mute must not end the call; the 30 s grace covers the rest). Output alone never starts a call, and neither does input alone.
All known apps share evidence tier **A** (the last column); what differs is where the bundle id comes from. **No app's audio behaviour (does it keep the microphone open while muted, which process holds
the streams, does it use a system daemon) has been checked in a real call.**

| App | Display name (label in notes and folders) | Main bundle id | Where the id comes from | Evidence tier |
|---|---|---|---|---|
| Cisco Webex | Cisco Webex | `Cisco-Systems.Spark` | public app catalog and an Info.plist listing | A: in + out |
| Slack (huddles) | Slack huddle | `com.tinyspeck.slackmacgap` | **read from an installed Slack** (its helpers are `com.tinyspeck.slackmacgap.helper`) | A: in + out |
| Discord | Discord | `com.hnc.Discord` | public app catalog | A: in + out |
| FaceTime | FaceTime | `com.apple.FaceTime` | **read from the installed app**. FaceTime's media may be hosted by a system daemon instead of the app; if so its calls are missed (add the daemon's id with `EXTRA_MEETING_APPS` or start by hand) | A: in + out |
| Skype | Skype | `com.skype.s4l` | Info.plist listing of Skype 8.x | A: in + out |
| Skype for Business | Skype for Business | `com.microsoft.SkypeForBusiness` | public listing | A: in + out |
| GoTo (GoToMeeting) | GoTo | `com.logmein.goto` | Info.plist listing | A: in + out |
| Amazon Chime | Amazon Chime | `com.amazon.Amazon-Chime` | public app catalog | A: in + out |
| BlueJeans | BlueJeans | `com.bluejeansnet.Blue` | Info.plist listing | A: in + out |
| Lark / Feishu | Lark / Feishu | `com.electron.lark` | Info.plist listing (Lark 5.x and Feishu share it) | A: in + out |
| Lark (newer builds) | Lark | `com.larksuite.larkApp` | public app catalog | A: in + out |
| KakaoTalk (voice / video talk) | KakaoTalk | `com.kakao.KakaoTalkMac` | **read from the installed app** | A: in + out |
| WhatsApp | WhatsApp | `net.whatsapp.WhatsApp` | **read from the installed app** and a public catalog | A: in + out |
| JANDI | JANDI | `com.jandi.osx.JANDI` | the Homebrew cask's quit stanza | A: in + out |

Naver Works is **not** in the table: no public source for its bundle id was found, and an id that cannot be verified is not hard-coded. Add it (or any other app) yourself:

```
EXTRA_MEETING_APPS=com.example.talk=Example Talk, org.example.meet
```

comma separated, each entry `bundle.id` or `bundle.id=Display Name` (the name is cut to 40 characters, control characters are removed; without a name the last part of the id is used). Find the id with
`mdls -name kMDItemCFBundleIdentifier /Applications/<App>.app`. Garbage entries (not a bundle id), duplicates (the first counts), more than 64 entries, our own app, Zoom, Teams, browsers and apps that are already in the
table are dropped, each with one line in `app.log` (at most five lines plus a count). An extra app is named on purpose, so the deny list does not apply to it. Some of these products may have been discontinued; they stay in the table for old installs.

### 3b.3 The generic rule (`CALL_DETECT=generic`, opt in)

`CALL_DETECT` = `known` (the table and `EXTRA_MEETING_APPS` only; the default) | `generic` (opt in) | `off` (nothing of 3b; Zoom, Teams, Meet and the manual start are not affected). Any other text reads as `known` and is logged.
The default is `known` on purpose: an install that has no `CALL_DETECT` in its `config.env` (every install before this feature) must not start recording apps that nobody named. On a Mac with an organisation policy a `CALL_DETECT` that neither `config.env` nor the policy sets is `off` (3b.6).
With `generic`, an app that is not in the table counts as a call when **all** of these hold:

- it is a GUI app: `NSRunningApplication` knows its main bundle id and the activation policy is not `prohibited` (daemons and background agents are never guessed; a helper process is folded into its main app);
- it is not on the built-in deny list and not denied by you (below);
- it holds the microphone input **and** an output stream together, continuously (a gap of 3 s or more starts over), for `CALL_GENERIC_SECONDS` (default 45, clamped to 10-600), after the same smoothing as above. The start debounce (4 s) comes on top, so a generic call is recorded about 50-60 s after the app opened both;
- afterwards the call is kept while the app holds the microphone input, and by its output for at most two more minutes after the input was last on (`CallTracker.genericOutputKeepSeconds`: a mute that closes the microphone must not split the call); output alone for longer ends it after the grace period. A known app is kept by input **or** output without that limit. Why: an app that keeps an output stream open for hours (a game, a player, a streaming tool) would otherwise keep a guessed recording, with the microphone track running, for as long as it plays (and `MAX_RECORDING_HOURS` would only restart it).

Its signal has **low** confidence (`DetectionSnapshot.best` prefers a known app that is in a call at the same time) and `callKind` `generic`. Output alone (music, a video) and input alone (a dictation tool) never count, and neither does input in one app and output in another.

**Built-in deny list** (data in `CallApps.denyRoots` / `browserRoots`; an entry is a bundle id root: the id or `<root>.…`): this app; Zoom and Teams (they have their own detectors: disabling one in `ENABLED_PLATFORMS` also keeps the generic rule away
from it); every Apple app and system process except FaceTime (Music, Podcasts, TV, QuickTime, Voice Memos, Safari and WebKit, Siri and dictation, Terminal, Xcode, GarageBand, Logic ...); browsers (Chrome and its variants and web apps, Firefox, Edge, Brave, Arc, Opera, Vivaldi,
Chromium, DuckDuckGo, Tor, plus everything in `BROWSER_BUNDLE_IDS`); media players and music (VLC, IINA, mpv, Movist, Spotify, Plex, Tidal); screen and audio recorders (OBS, Kap, CleanShot, Loom, ScreenFlow, Camtasia and Snagit, Screen Studio);
dictation and speech tools (Nuance, MacWhisper, Talon); voice assistants (Claude, ChatGPT / OpenAI, Gemini: their voice mode holds the microphone and plays sound and is not a call); audio production and routing (Ableton, Audacity, Reaper, Avid, Rogue Amoeba, BlackHole);
terminals; IDEs and editors. A known app is looked at first, so FaceTime is a call app although Apple's other apps are denied. The list is a default, not a promise: an unlisted dictation tool or game that holds both streams for 45 s **will** be recorded until you
choose "Never record" for it.

**Your decisions** (`SUPPORT_DIR/call-apps.json`, mode 0600, written atomically): one entry per bundle id (a meeting page: `web:<siteID>`, for example `web:whereby`; the browser's own id is never denied) with `decision` (`allowed` | `denied`), the app's display name and the time of the last change; no titles, no addresses, no meeting content.
`denied` = never record this app, whatever found it (known, extra, generic or a meeting page); `allowed` = it was recorded and you did not object (**every** recording lists its app as `allowed`, whatever found it). `allowed` never lifts the built-in deny list; `EXTRA_MEETING_APPS` does.
Format: `{"version": 1, "apps": {"net.whatsapp.WhatsApp": {"decision": "denied", "name": "WhatsApp", "updated": "..."}}}` (ids are lower-cased when read). A hand edit is picked up when you open the menu.
The list **fails closed**:

- A file that exists but cannot be used (not valid JSON of the form `{"apps": {...}}`, empty, no read permission, a directory in its place) is **left untouched** and **every call of another app is paused** (known, extra, generic and meeting pages: without the file the app cannot know what you denied; Zoom, Teams and Meet are not affected). The menu and `app.log` say why; no decision can be changed until you fix or remove the file and open the menu.
- Inside a readable file only an entry that says `allowed` (any case) allows. Any other decision text (`"deny"`, `"Denied "`, a number, a missing decision) is read as `denied` and logged, and the next save writes `denied`; only an entry whose key is not a bundle id is skipped. Two keys that differ only in case: `denied` wins. Past 500 entries the denials are kept first.
- A decision whose write fails (a read-only folder) stays in force until the app quits, survives every menu `reload()`, and is written again at the next read once the file can be written. `set()` reads the file again first, so a file that went bad since the last read is never replaced, and a hand edit is not lost.

**What you see.** When the generic rule starts a recording the app posts a notification that names the app, whatever `NOTIFY_RECORDING` says (it is the one sign that a recording is a guess):
"`<App>` looks like a call: recording started. Not a call? Menu > Never record `<App>`" (subtitle and body; the Korean text says the same). A recording of a named app (a table app, an extra app, a meeting page) posts the normal start notification (`NOTIFY_RECORDING`).
While **any** call of another app is recorded the menu has the item **Never record `<App>`**: one click remembers `denied` and stops the recording like "Stop Recording Now" (it is kept and queued like any stop by hand; `mcap forget <folder>` deletes the meeting if it was not a call).
The submenu **Call Apps** lists every app of the built-in table, your `EXTRA_MEETING_APPS`, the meeting-page sites (with `CALL_BROWSER_URLS=on`) and every other app that was recorded or that you decided about (check mark = recorded, no mark = never record) and flips one per click, **also before the app's first call**: that is how you keep FaceTime or WhatsApp out without editing the file.
With `CALL_DETECT=off` neither exists.

### 3b.4 What a recording of a call looks like (contract, additive)

- Session folder in staging: `YYYY-MM-DD_HHMM_call` (collision suffix `-2`, ...). The published folder is `YYYY-MM-DD_HHMM_<slug>` as always, the slug being the calendar or note title, else the app's name (`Slack-huddle`).
- `session.json`: `platform` = `"call"`, `platform_label` = the app's display name (`"Slack huddle"`; the note, the transcript header, the title fallback and the folder name read it), `app_bundle_id` = the app's main bundle id (the browser's for a meeting page), plus two keys that only a call writes: `app_name` (the display name) and `call_kind` (`known` | `extra` | `generic` | `web`).
  The other platforms' `session.json` has exactly the keys it always had. No title hint and no address are written for a call.
- Old sessions are untouched: every consumer of the platform string keeps its old values, an unknown platform value reads as "no platform", and a session without `app_name` / `call_kind` is read as before.
- Calendar lookup: a `call` recording never takes a Meet, Zoom or Teams event (it is another app); any other event follows the usual overlap rules. The no-speech discard (less than 20 s of speech) applies to calls like to every session.
- `SYSTEM_AUDIO_MODE=app` taps the processes whose bundle id starts with the call app's (the app and its helpers; the browser's for a meeting page). With `MIC_MUTE_GATE=on` the app's own microphone state is not available as a mute signal for a call app (it reads "unknown" and records); the menu's Pause Microphone is the guaranteed way.

### 3b.5 Meeting pages in Chrome (`CALL_BROWSER_URLS=on`, off by default)

The address of Chrome tabs is read **only** when `CALL_BROWSER_URLS` is on (and `CALL_DETECT` is not off, and `ENABLED_PLATFORMS` is not empty), with the same machinery and the same Automation permission as Google Meet (`TabQueryPolicy`, section 5).
So nobody who uses native apps only is ever asked for it: with the default nothing in the app can ask Chrome for anything, and `setup` asks for the Chrome Automation permission only when `meet` is enabled or this key is on. A tab list that is read for this purpose keeps nothing but the site and the tab's identity
(no address, no room name, no title), and drops a Google Meet tab at once. A tab counts when its address matches the table (data, one row per site: `WebMeetingURL.table` in `CallApps.swift`; exact host or a dotted suffix of a domain, `https` only; `whereby.com.evil.com` never matches):

| Site (`siteID`, label) | Matches | Notes |
|---|---|---|
| `webex`, "Webex (web)" | `*.webex.com`: `/meet/<name>`, `/<site>/j.php`, `/wbxmjs/joinservice/…`, `/webappng/sites/<site>/meeting/…` | link formats from public Webex guides |
| `whereby`, "Whereby" | `whereby.com` and `*.whereby.com`: a first path segment that is a room name (not `pricing`, `blog`, `login`, ...) | approximate: a marketing page that is not in the list of reserved words would match; the audio requirement below keeps it from recording |
| `jitsi`, "Jitsi Meet" | `meet.jit.si/<room>` | only the public instance |
| `teams-web`, "Teams (web)" | `teams.microsoft.com`, `teams.live.com`, `teams.cloud.microsoft`: `/l/meetup-join/…`, `/dl/launcher…`, `/meet/…`, `/v2/?meetingjoin=true` | Teams in a browser is a `call`, never the native Teams platform |
| `zoom-web`, "Zoom (web)" | `zoom.us`, `zoom.com` and subdomains: `/wc/…` | the web client; a normal `/j/…` join page does not match |

The call needs the tab **and** Chrome holding the microphone and playing sound (smoothed, like a known app); it is kept while the tab stays open and Chrome has either, a tab list that fails mid-call never ends it, and a tab list that is read without the page ends it after the grace.
There is **no** low-confidence fallback without the tab (Chrome audio alone is never a call here: that would be Google Meet). Google Meet itself is not in this table: `meet.google.com` stays behind `meet` in `ENABLED_PLATFORMS`, with its own rules (section 3).
Only Chrome is supported (Safari, Firefox and others cannot be asked for their tabs; they are on the deny list so the generic rule does not guess them either). All patterns are unverified against real calls.

### 3b.6 Cost and safety

- Known apps: both flags of their processes are read every poll (about 3 ms on the reference Mac with three Slack / FaceTime process objects). The generic scan (one property read per process object, 28 ms median / 45 ms p95 with 60 objects) only runs while some audio **input device** is running at all
  (`InputActivityGate`: one read per input device, 0.4 ms), i.e. almost never; apps already being tracked are read regardless. All of these are Core Audio reads of process objects: no permission, no microphone access, nothing opened.
- The generic rule never opens a stream and never reads a window, a title or any content; the only things it keeps are bundle ids, display names and your decisions (`call-apps.json`), and `app.log` lines about them (`detect: call <name> [kind id] inCall false->true ...`).
- The call rule is off when `ENABLED_PLATFORMS` is empty ("manual recording only") and with `CALL_DETECT=off`. `ENABLED_PLATFORMS` does not otherwise bound it: `ENABLED_PLATFORMS=zoom` still records a Slack huddle under `known`.
- **Policy.** `CALL_DETECT`, `CALL_GENERIC_SECONDS`, `EXTRA_MEETING_APPS` and `CALL_BROWSER_URLS` are on the policy whitelist (`PolicyLayers.whitelist` = `DEFAULTS_WHITELIST` of `pipeline/mcap/policy.py`), so a policy can set them in `defaults` or lock them in `enforced`. On a Mac with a policy a `CALL_DETECT` that neither `config.env` nor the policy sets is `off`, so a company baseline of `ENABLED_PLATFORMS=zoom,teams` records only Zoom and Teams (`config.env.company.template` does not set it, to leave the policy's own value alone). With `recording.enabled=false` a call of another app is skipped with one line in `app.log` and the app is left alone for 5 minutes: no "Recording failed" notification (nobody opened a meeting; Zoom and Teams keep theirs).

## 4. Smoothing, debounce, grace (numbers)

| Parameter | Value | Where |
|---|---|---|
| input / UDP smoothing: on after | 1.5 s of raw on (2 polls at the 2 s default) | `DetectionTuning.inputRise`, `udpRise` |
| output smoothing: on after | 7.0 s of raw on (5 polls = 8 s span at 2 s polling) | `DetectionTuning.outputRise` |
| off after | 3.0 s of raw off (bridges one missed poll) | `DetectionTuning.fall` |
| start debounce | `START_DEBOUNCE_SECONDS` (4) | state machine |
| Zoom STRONG threshold | `ZOOM_STRONG_SOCKETS` (6, whole number 1-64; 1 = any socket is strong) | `Detector.classifyZoom`, `ZoomTierSettings` |
| Zoom WEAK debounce | `ZOOM_WEAK_DEBOUNCE_SECONDS` (15; 0 = off, else 1-300; never below the start debounce) | state machine (`weakDebounce`) |
| weak start confirmation | 20 s of inCall after the start, or one STRONG poll | `SessionController.weakConfirmSeconds` |
| end notice held back | normal end with < 60 s of inCall, until the pipeline outcome (30 min at most) | `SessionController.deferStopNoticeBelowSeconds` |
| flicker tolerance | 3 s | `DetectionStateMachine.flickerTolerance` |
| grace Meet | `GRACE_SECONDS` (20) | state machine |
| grace Zoom / Teams / calls of other apps | `max(GRACE_SECONDS, 30)` | `DetectionStateMachine.zoomTeamsMinGrace` |
| generic call hold | `CALL_GENERIC_SECONDS` (45; 10-600) of input + output together, then the start debounce | `CallTracker`, `CallDetectSettings` |
| generic app forgotten | 60 s without any audio IO | `CallTracker.forgetAfter` |
| device list of the generic scan gate | read again every 30 s | `InputActivityGate` |
| tab list refresh | 4 s while looking for a call, 12 s once a Meet call is established; 10 s after an error | `ChromeTabs` |

Smoothing is time based (not poll-count based), so it behaves the same at 1 s (`probe --watch`) and 2 s (app) polling.

`DetectionStateMachine` (pure logic, contract in Types.swift) [T]:
- **Start**: the same meeting (same platform; same Meet code when both sides know one) inCall for `START_DEBOUNCE`
  (Zoom evidence that is WEAK only: `max(START_DEBOUNCE, ZOOM_WEAK_DEBOUNCE_SECONDS)`, section 3).
  A gap shorter than the flicker tolerance does not restart the debounce; a gap longer, another platform, or another code does.
  When several platforms are inCall the high-confidence one is preferred (`DetectionSnapshot.best`), the current candidate is
  kept while its signal stays on. A LOW signal starts a recording like any other.
- **Stop**: the session's platform has had no inCall signal for the effective grace. Each inCall poll re-arms the timer, so a
  signal that keeps flipping inside the grace never stops the session (except a Zoom weak-only run that began after a gap and has not lasted the weak
  debounce: it re-arms nothing, section 3, but while it is on it does not end the session either; the first poll without a signal does). A stop is
  never decided on a poll that carries the platform's signal. Another platform's call does not extend a session.
  Reason is always `.meetingEnded` (disk, sleep, max duration, user stop are the controller's).
- **Split** (Meet only): another code persists for the Meet grace -> `.split`. Flipping back to the old code cancels it,
  a gap over the flicker tolerance cancels it, a vanished new code ends in a normal stop. A missing code (fallback / failed
  tab query) neither splits nor stops; a session that started without a code adopts the first known one. Zoom/Teams never split.
- **Manual recording** (`adoptManualRecording()`): the machine reports recording and never returns an action; the caller ends it
  with `reset()`.
- **reset()**: forgets session, candidate and pending split. A meeting that is still running becomes a fresh candidate and
  starts again after the debounce (the controller suppresses that where it must not happen).
- **Clock**: a wall clock that moves backwards re-anchors every timer (a one hour step back would otherwise freeze the grace).

Timeline at defaults (2 s polling), measured in the virtual-clock scenarios [T]: joining a Meet call -> recording starts 8 s after
the stream opens (the poll that sees it, 2 s smoothing, 4 s debounce); leaving -> stop 22 s after the streams close (the 3 s
smoothing hold, then 20 s grace counted from the last in-call poll); Zoom/Teams stop 32 s after the last signal; a Zoom call with STRONG evidence starts like a Meet call (sockets >= 6 or input: about 6 s after the first socket),
one with WEAK evidence only about 17 s after it (2 s smoothing + 15 s); a back-to-back Meet
split needs the next meeting's tab to be the front tab for the start debounce (4 s of tab-list observations, taken at the fast 4 s rate
while it is timed) and then the 20 s Meet grace.

## 5. Chrome tab queries: safety and gating

`TabQueryPolicy` decides **whether AppleScript may run at all**:

| Context | Tab queries |
|---|---|
| `LaunchGuard.isSignedAppLaunch`: the app has a bundle id (`AppInfo.bundleID`: its `Info.plist`; a bare binary has none) **and** started by launchd / LaunchServices (`ppid == 1` or `__CFBundleIdentifier` is the app's: the LaunchAgent, or `open -n -a ...`) | enabled |
| any other process (terminal, agent shell, scratch builds, `selftest-detector`), **including the app binary exec'd from a shell** (the bundle id alone is not enough: macOS would attribute the prompt to the parent app) | **disabled**: the Chrome backend is never touched, `probe` says so, Meet uses the LOW fallback |
| other process with `--tabs` **and** `MC_ALLOW_APPLESCRIPT=1` | enabled (manual diagnostic; the Automation prompt, if any, goes to the calling terminal) |
| `meet` not in `ENABLED_PLATFORMS` (the default) | no tab query at all, whatever the rows above say |

`ChromeTabs` then adds gates in this order, each avoiding contact with Chrome [T]:
policy -> Chrome configured (`BROWSER_BUNDLE_IDS` has a `com.google.Chrome*` entry) -> Chrome has audio IO (raw or smoothed) ->
cache -> **Chrome verified running with `NSRunningApplication`** (a `tell` would launch it) -> **Automation already authorized**
(`AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)`; `-1744` not asked yet and `-1743` denied never run the script, so the
app can never raise the prompt by itself) -> script. One dedicated serial queue runs `NSAppleScript`, the script is wrapped in
`with timeout of 3 seconds`, the caller waits at most 5 s, and a query that is still running blocks new ones (no pile-up behind a
hung Chrome). The script reads only `URL`, `title` and window `mode` (bulk `URL of every tab of w`), so "Allow JavaScript from
Apple Events" is not needed. Only `meet.google.com` tabs are kept or printed; other tabs' URLs and titles are dropped at once.

The Automation prompt appears only in `requestChromeAutomationPermission()` (called by `setup`): it returns `authorized`,
`denied: <how to fix>`, `not-running: open Google Chrome and re-run setup`, or `refused: ...` (any process that is not
`LaunchGuard.isSignedAppLaunch`, unless `MC_ALLOW_PERMISSION_PROMPTS_FROM_ANY=1`). `setup` calls it only when `meet` is enabled.

## 6. Evidence format (what `app.log` and `probe` show)

Every `PlatformSignal.evidence` is a list of short strings, always in this order:
```
chrome-audio in=1 out=0 raw=1/0 io=4214:in      stable in/out, raw in/out, pids that carry IO ("-" if none)
tabs: ok tabs=12 meet=[*abc-defg-hij]           ok | disabled | idle | automation-denied | automation-not-asked | chrome-not-running | unsupported | error(...)   (* = chosen)
tier=HIGH (code tab + in + out)                 HIGH / MEDIUM (... in only | out only) / LOW (no tab info: chrome in+out | nickname tab ...)
```
```
zoom-audio in=0 out=0 raw=0/0 io=-
udp main-pid=787 sockets=0 stable=0             main-pid=none sockets=n/a when Zoom is not found
via=udp | via=udp+input | via=input | output alone does not count
tier=weak (sockets=4<6, no input, no output)    only while Zoom shows sockets or input; tier=strong (sockets=7>=6[, input][, output+sockets=3>=3])
```
```
teams-audio in=1 out=1 raw=1/1 io=5000:in+out
via=input | output alone does not count
```
```
call-audio Slack huddle in=1 out=1 raw=1/1 io=7001:in+out        a known / extra / generic app: name, smoothed in/out, raw in/out, pids that carry IO
app=known com.tinyspeck.slackmacgap                                 app=known | extra | generic <main bundle id>
generic: in+out held 31 s of 45 s                                   generic only
via=in+out | via=keep (in only) | via=keep (out only) | needs in+out [for 45 s]
browser-audio in=1 out=1 raw=1/1 io=4214:in+out                     a browser meeting page: the browser's flags
web=whereby tab=yes                                                 tab=yes | no | n/a (tab list not available); via=tab+in+out | via=keep (...)
```
`Detector` logs one `detect:` line per platform (per app for calls of other apps: `detect: call Slack huddle [known com.tinyspeck.slackmacgap] inCall false->true ...`) whenever `inCall` flips (with the evidence), the tab-query status when it changes
(`WARN` for denied / not asked / error), and Core Audio enumeration failures. `SessionController` logs the snapshot at start, stop and split.

## 7. `probe` and `selftest-detector`

```
probe                                one snapshot (human readable)
probe --json                         the same as one JSON document
probe --watch [--interval 1] [--minutes 90]   live; prints a line only when something flips, flips spelled out (yellow on a terminal)
probe --bench [N]                    timing of poll() (first poll = cold, then steady state)
probe --tabs                         with MC_ALLOW_APPLESCRIPT=1 outside the app: enable tab queries (see section 5)
selftest-detector                    960 device-free checks, exit 0 only if all pass
```
Run the live checks through the app so Automation and Core Audio are attributed to Catch Everything and tab queries are enabled
(`-n` is required: without it `open` only re-activates the already running menu-bar app and ignores the arguments; a watch started through `open` cannot be stopped with Ctrl-C: it ends after `--minutes`, or `pkill -f 'probe --watch'`):
```bash
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args probe --watch
```
The `ZOOM` section of `probe` shows `current tier: weak|strong|none (reason)` of this poll, the two thresholds with their keys
(`ZOOM_STRONG_SOCKETS`, `ZOOM_WEAK_DEBOUNCE_SECONDS`, read from config.env like the app) and what each tier does; the live line says `tier weak|strong`
next to the socket count, and a tier change is a printed flip (`zoom.tier`). The idle flicker therefore reads `current tier: weak (sockets=4<6, no input, no output)`
in `probe --watch` without any recording.

Sections of the table and the live line (columns `in raw/stable`, `out raw/stable`, `tab <chosen code or status>`, `udp <main pid>`):
`PLATFORM SIGNALS` (inCall, confidence, evidence) · `FLAGS` (raw vs smoothed) · `FAMILY PROCESSES` (PID, bundle id, in, out, Chromium
role such as `audio-service`, UDP per Zoom/Teams process) · `ZOOM` (main pid UDP, every child process with its UDP sockets, `-key <digits>`
flag without the digits) · `TEAMS` (relay-port socket count) · `CHROME / MEET` (running, tab-query status, classified Meet tabs, Chrome
network-service sockets) · `OTHER PROCESSES WITH AUDIO IO` · `AUDIO DEVICES RUNNING SOMEWHERE` (incl. "Microsoft Teams Audio").

## 8. Verified here vs not

Verified [T] by `selftest-detector` (960 checks) and the shell's `selftest-session` (2738 checks, uses the real state machine);
the whole `app/Sources` tree compiles with `-warnings-as-errors`:
smoothing; family mapping; URL classifier (look-alike hosts, queries, case); tab parsing from synthetic Apple Event descriptors; tab choice;
tab-query policy and prompt refusal; the Chrome gate (not running / not asked / denied / disabled / no audio IO -> zero script calls;
cache; error back-off); all three formulas incl. every fallback; libproc UDP read-back; debounce, flicker, grace per platform, flipping
signals, split rules, manual adoption, reset, clock jumps; whole-pipeline call scenarios (Meet join / mute / leave / dropouts /
stale tab / media tab / chime / denied / disabled / back-to-back, Zoom UDP / input / media rebuild / helper UDP, Teams output-only);
`probe` rendering and flip diff; Zoom evidence tiers: the tier table, the evidence text of the observed flicker and join, 2 h of flicker (4/6/10/14 s every 120 s) with
no recording under the defaults (and many with `ZOOM_WEAK_DEBOUNCE_SECONDS=0`), real joins starting exactly as before (also with the sockets ramping 1 / 2 / 4 / 7 and with a slow ramp), weak calls starting after 15 s, a flicker 10 s after a
meeting end not moving the stop, a flicker still on at the end of the grace delaying the stop by its own length only, a flicker after the stop starting nothing,
a Zoom reconnect inside a meeting (10-28 s without sockets, back weak or ramping) staying ONE recording exactly as before the tiers (state machine, detector pipeline and controller),
a gap beyond the grace still ending it, Teams unchanged; config parsing of both keys and the notification gating in `selftest-session`.
Calls of other apps (3b) with fake process monitors: every one of the 14 known apps (idle, start, stop after the grace, input alone, output alone), helper-to-main mapping, `EXTRA_MEETING_APPS` parsing (garbage, duplicates, 10 000 entries, a megabyte of noise,
control and bidi characters), the thresholds of the generic rule (45 s, gaps, a single missed poll, input or output alone for 10 minutes, the keep rule: input, bounded output keep, 6 hours of output alone, daemons, names), the deny list (every category, in one world with one real app), your decisions (persistence,
0600, corruption, an unreadable file (mode 000), a directory in its place, a file that goes bad after the last read, mistyped decision words, case collisions, the 500 entries cap with denials first, an unwritable folder and `reload()` after a failed write, meeting pages by site), one recording per call (15 minutes, dropouts, two apps at once, a Zoom call at the same time, and Zoom, Teams or Meet joining while a call app is recorded: the take-over, its debounce and flicker tolerance, the WEAK Zoom flicker that must not take over), `CALL_DETECT` off / known / generic, Google Meet staying out of every call rule,
the browser URL table (positive and negative, look-alike hosts) and the browser pipeline (tab, audio, closed tab, failing tab list, denied permission, the switch off), the state machine for call signals, the controller (notifications, 'Never record' for every kind of call app, no start while another recording runs, the take-over of a call recording, one log line for an ignored call, the kill switch without a banner), the Call Apps rows and menu texts and
`session.json` of a real Recorder for a call (and the other platforms unchanged); `PlatformSignal` / session.json compatibility with data from before the call platform.

Verified live [L] on the reference Mac in an idle state (Zoom running idle, Chrome running, no call): all three platforms `inCall=no`;
Chrome pids 764 (main), 4214 (`audio-service`), 4215 (`video-capture`); Zoom 787 (main, 0 UDP) and `caphost` 1455 (0 UDP) and its
child processes (0 UDP); Chrome network service 1177 holds 30 UDP sockets (12 connected to :443, rest mDNS), which is why only the Zoom main
pid is counted; Teams has no Core Audio client; `Microsoft Teams Audio` not running; `probe --watch` flips are seen for a quiet
`afplay` (non-family process, speakers device); steady-state poll 3 ms median.

**Not verified (needs a real call or the signed app):** every call app of section 3b (the signals, which process holds the streams, what mute does, FaceTime's daemon, the browser link formats, a generic false positive in real use) and everything tagged [?] in the research: Meet `in`/`out` in lobby, alone, muted
and after leaving; what the Meet tab URL/title look like after leaving; Zoom main-pid UDP and input during a meeting, muted, in a
waiting room, after leaving; Teams IO owner and mute behaviour; Bluetooth devices; Meet PWA / incognito / second-profile coverage of
`windows`; the AppleScript text itself (it was never compiled or run against Chrome, by design) and the real
`AEDeterminePermissionToAutomateTarget` results (-1743 / -1744 / noErr); `-key <digits>` in Zoom argv.

## 9. Known limitations (by design, recall first)

- Chrome has no per-tab audio state: a stale post-call Meet tab plus any sustained Chrome output (YouTube, Spotify web) starts a MEDIUM
  session (selftest pins this: L-11). A 6 s burst (notification) does not. Mic use by another tab (voice typing) with a stale Meet tab
  starts one too. The pipeline discards sessions without speech, but a video with speech makes a junk session.
- A Meet session in the lobby (mic meter running) starts early; that is acceptable (the start of the meeting is captured).
- A Meet call in an app window that `windows` does not list (PWA?) is missed when tabs are available but empty (L-15).
- Zoom `Settings > Audio > Test Mic` (input without UDP) starts a session (L-08).
- If Meet closes the mic stream while muted and nobody speaks (output closed too), the call looks over; unverified (L-10).
- A second Meet tab opened (lobby of the next meeting) while still in the first call does NOT split it (sticky chooser, section 3); it
  only takes over once it has been the front tab for the start debounce, and the session then splits after the Meet grace. Looking at the
  next meeting's lobby in the front tab for 4 s or more while the first call is still running does split it.
- One poll can block up to 5 s when Chrome hangs; later polls do not pile up behind it.
- Zoom WEAK evidence costs the first ~17 s: a real call with 1-5 sockets, no input and no output IO (a call with the mic never opened and nothing played) is
  recorded only from about 17 s after its first socket (2 s smoothing + 15 s). Strong evidence (6+ sockets, mic, or output with 3+ sockets) is unaffected.
- A call that started strong, lost all sockets for longer than the grace (30 s) and then came back with weak evidence only is split (the meeting looked over): the first
  recording ends at its grace, the second starts after the weak debounce (the first ~17 s of the return are not recorded). A gap shorter than the grace is one recording
  whatever the return looks like (reconnect tests, section 8).
- The Zoom 7.0.6 idle flicker is absorbed, not explained: nobody knows what opens the 4 sockets every ~2 minutes. Measured with the real detector and state machine on a virtual
  clock: a flicker has to keep its sockets for 16.5-18 s (depending on the 2 s poll phase) to record, against 4.5-6 s before the tiers; the observed ones keep them 2-4 s. If a flicker ever lasts 17 s or more it records
  (and is discarded as 'no speech' by the pipeline, but with its folder and sleep-prevention toggle; its start / end notices stay away unless it lasts another 20 s).
  Raise `ZOOM_WEAK_DEBOUNCE_SECONDS` if that ever shows up in `app.log` (`weak evidence ended after N s` lines tell how long they get).

- Generic rule (3b.3): an app that is not on the deny list and holds the microphone and plays sound for 45 s is recorded and posts the "looks like a call" notification: a dictation tool that also plays sound, a game with voice chat, a virtual machine or remote desktop with audio redirection, an AI app that is not on the list.
  The first 45-50 s of a generic call are not recorded (the app has to prove itself first); use a known app (the table, `EXTRA_MEETING_APPS`) to avoid that. A call app that releases both streams while idle starts over after every gap of 3 s or more.
- Known apps (3b.2): not one of them has been observed in a real call. An app whose media runs in a system daemon (FaceTime may), whose microphone is not an input stream of its own processes, or that never opens an output stream while you are the only one in it, is missed.
- The gate of the generic scan (`InputActivityGate`) was only seen answering "no input device is running" on an idle Mac; that it answers "yes" while a call holds the microphone (a Bluetooth headset, an aggregate device) has not been observed. If it never does, the generic rule never starts (known apps and `EXTRA_MEETING_APPS` do not use it).
- `probe` does not list call apps yet (its detector is built without the call rule); `app.log` has their `detect: call ...` lines.

## 10. Live-test checklist for the tester (L-01 .. L-38, mapped to `probe --watch`)

Start `probe --watch` (section 7) before each block; note wall-clock times next to the flips it prints. Keep the output for a bug report (`docs/LIVE_TEST.md` section 8).
Abbreviations: **in/out** = the `in raw/stable out raw/stable` columns and the per-pid rows; **udp** = `udp` column and the `ZOOM` section.

**Google Meet (59 of the last ~69 meetings)**

| ID | Do this | Look at / expected | Decides |
|---|---|---|---|
| L-10 | `meet.google.com/new`, alone. Lobby 10 s, Join, mute/unmute 3x (muted once for 60 s) | `FAMILY PROCESSES` rows of the `audio-service` pid and the `meet[...]` line: lobby expect in=1 out=0; joined alone: is out=1?; muted: does in stay 1? | tiers; whether START may use out; Variant B (keep = tab && in) |
| L-11 | YouTube audio in a second tab, no meeting; then with a stale post-call Meet tab | no Meet tab: inCall stays `no`. Stale tab: a MEDIUM session starts after ~8 s (known limitation) | FP mitigation |
| L-12 | At each stage: lobby, in call, camera off, presenting, after Leave (post-call page), after "Return to home" | `CHROME / MEET` tab list: kind, URL, title per stage; does the URL stay `meet.google.com/<code>` after leaving? does the title change? | title/URL discriminators, post-call handling |
| L-13 | Leave. Leave the tab open 60 s | time between your click and `meet.in.raw 1 -> 0` / `out`; no new `start` | grace value |
| L-14 | A real meeting with 2+ people, a silent minute | out stays 1 through silence | keep-alive via out |
| L-15 | Join from the Meet PWA window (if any), an incognito window, a second Chrome profile | are they in the tab list (`incognito` flag)? which pids flip? | tab-query coverage |
| L-16 | Run the app with Automation denied (System Settings > Privacy > Automation), then allowed | denied: `tab query: automation-denied`, evidence `tier=LOW`, no code/title; allowed: `ok` | fallback path, AE states |
| L-17 | any Meet call | `FAMILY PROCESSES` role column: the pid that flips should be `audio-service` (bundle `com.google.Chrome.helper`) | IO owner |
| L-18 | repeat one call with AirPods | same flags with Bluetooth in/out | Bluetooth risk |

**Zoom**

| ID | Do this | Look at / expected |
|---|---|---|
| L-01 | Zoom > New Meeting (alone, computer audio) | `zoom ... udp` >= 1 on the main pid (typically 4-6) and `via=udp`; if the main pid has 0 but a `child` row has sockets, note which child |
| L-02 | Zoom idle, and 10 s after the meeting window closes | udp 0 (it is 0 now [L]); note any lingering socket |
| L-03 | mute/unmute 3x, video off/on | in stays 1 while muted? udp unchanged? |
| L-04 | Leave; repeat with End Meeting for All | time to `udp 4 -> 0` and `in 1 -> 0`; a lingering in=1 would be the old 5.9.x mic-dot bug |
| L-05 | start screen share | new `child` rows (names), `argv has -key <digits>` flag |
| L-07 | join a meeting with a waiting room, wait 30 s, get admitted | no signal while waiting, `inCall` at admission |
| L-08 | Zoom > Settings > Audio > Test Mic (not in a meeting) | in=1 udp=0 -> a session starts (known) |
| L-09 | breakout room, or Wi-Fi off/on 10 s mid-meeting | gaps in udp/in versus the 30 s grace: no `stop` should appear |
| L-19 | join without computer audio | udp >= 1, in=0 -> `via=udp` carries the call; note `tier`: strong if sockets >= 6 |
| L-21 | Zoom idle (signed in, no meeting) for 10 minutes with `probe --watch` | the ~2 minute flicker shows `zoom.tier: none -> weak` and `udp 0 -> 4` for a few seconds, `inCall` flips, **no** recording and no notification; `app.log`: `weak evidence ended after N s without a recording` |
| L-22 | a call you join with the mic never opened and nothing playing (join muted without computer audio) in a 1:1 | `sockets` and `tier` through the call: if `tier=weak` for the whole call, the recording starts ~17 s in (expected, documented); note the socket counts |
| L-23 | in a meeting, switch Wi-Fi off for ~25 s and on again (a Zoom reconnect; 26 s were seen live) | `udp 7 -> 0` for ~25 s, then which counts and `tier` the return shows (`1/2/4 ...`, weak at first); `app.log` has **no** `stop (meeting-ended)` and no second `start:` and the Meetings folder gets ONE session |

**Other calls (section 3b)**: `probe` does not show them yet, so watch `app.log` (`tail -f ~/Library/Logs/MeetingCapture/app.log | grep 'detect: call'`) and the notifications.

| ID | Do this | Look at / expected |
|---|---|---|
| L-30 | Slack: start a huddle alone (mic on), 60 s, mute / unmute 3x, leave | `detect: call Slack huddle [known ...] inCall false->true` about 8 s after the huddle opens, the recording starts ~4 s later; mute does not end it; `false` about 3 s after leaving, `stop` 30 s later. Note which process holds the streams (`io=` in the evidence) |
| L-31 | FaceTime audio call (two Apple devices), 60 s | does `FaceTime` show `in=1 out=1`? if not, `probe` the other processes with IO (`OTHER PROCESSES WITH AUDIO IO`) to see whether a daemon holds them |
| L-32 | Discord voice channel, WhatsApp / KakaoTalk call, Webex app meeting | one row per app as L-30; write down the ids that differ from the table |
| L-33 | an app that is not in the table (a Whereby / Jitsi call in a native wrapper, a game with voice chat) for 2 minutes with `CALL_DETECT=generic` | after ~50 s the "looks like a call" notification with the app's name; Menu > Never record `<App>` stops it, `call-apps.json` has `denied`, the app is not recorded again |
| L-34 | play music or a video with no microphone use for 10 minutes; use a dictation tool for 2 minutes | no `detect: call` line at all |
| L-35 | `CALL_BROWSER_URLS=on`, `setup` (Chrome Automation prompt), join a Whereby / Jitsi room in Chrome, 60 s, close the tab | `web=whereby tab=yes`, start ~8-12 s after the mic and sound open, stop ~30 s after closing the tab; with the key off (default) nothing happens and no Automation prompt appears |
| L-36 | open a Google Meet tab and call in it with `meet` NOT in `ENABLED_PLATFORMS` (generic on, browser addresses on) | nothing is recorded |
| L-37 | a Slack huddle (or Discord channel) is on and recorded, then join a Zoom meeting (and later a Teams call) without leaving it | about 4 s after Zoom's STRONG evidence `app.log` has `split: meeting changed (call:... -> zoom:-)`, the huddle recording is queued, the Zoom meeting is recorded; the huddle that is still on starts nothing (one `is in a call while the recording zoom` line) |
| L-38 | open the menu > Call Apps before any call of a messenger happened; switch FaceTime (or WhatsApp) off; then place a call in it | the submenu lists the whole table; the app shows "(never record)" and `call-apps.json` has `denied`; the call is not recorded and `app.log` has no `start:` line for it. Also: `chmod 000 ~/Library/Application\ Support/MeetingCapture/call-apps.json`, open the menu: the header says the file cannot be read and no call app is recorded until you `chmod 600` it again |

**Teams**

| ID | Do this | Look at / expected |
|---|---|---|
| L-06 | Meet now: pre-join (mic meter), join, mute/unmute, leave | `FAMILY PROCESSES` (`com.microsoft.teams2` vs `.helper` carries in/out); `TEAMS` relay-port count and the main process UDP row (connected vs unconnected, remote ports); `Microsoft Teams Audio` running; time to drop after leaving |
| L-20 | receive and decline an incoming call (ringtone) | out=1 without in: `output alone does not count`, no session |

Decision rules after the tests:
1. Meet `in` stays 1 while muted -> adopt Variant B: once `in` was seen in the session, keep = `tab && in` (edit `evaluateMeet`); if `in` drops while muted, keep the generous `tab && (in || out)`.
2. Meet `out` is 0 when alone in a call -> start must not need `out` (already true for code tabs; only the LOW fallback needs in+out).
3. Zoom main pid holds no UDP in meetings -> count the Zoom children except `ZoomCefHelper*` (`NetworkProbe.childPIDs` + `executableName`, in the zoom branch of `Detector.poll`).
4. Teams IO lives in a helper -> already covered (prefix). If L-06 shows relay sockets only in calls, add `connected(..., toPorts: teamsRelayPorts) >= 1` to `evaluateTeams`.
5. Flag drop times in L-04 / L-13 / L-09 -> adjust `GRACE_SECONDS` (Meet) or `zoomTeamsMinGrace`.
7. Calls of other apps: an app whose ids or streams differ from the table (L-30..L-32) is fixed in `CallApps.known` (or `EXTRA_MEETING_APPS` for you); a false generic recording (L-33 / L-34) goes on the deny list (`CallApps.denyRoots`) if it is a kind of app, else stays a "Never record" decision.
6. Zoom tiers: if L-01 / L-22 show real calls with fewer than 6 sockets and no mic, lower `ZOOM_STRONG_SOCKETS` (but keep it above the idle flicker's 4); if idle flickers ever
   last 15 s or more, raise `ZOOM_WEAK_DEBOUNCE_SECONDS`. `ZOOM_WEAK_DEBOUNCE_SECONDS=0` restores the old behaviour exactly.
