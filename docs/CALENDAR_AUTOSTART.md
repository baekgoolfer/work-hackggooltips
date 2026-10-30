# Calendar autostart (Google Calendar, read-only)

Calendar autostart lets the app start a recording by itself for an **in-person conversation that is in your Google Calendar**, without you pressing
anything. It is **off by default**, it is a **single-user feature** (one Mac, one owner, one Google account, a Google Cloud project that you create
yourself), and it records people who are talking in the room. Read the warning first.

## 1. Warning: recording people (read this before you turn it on)

- **A recording that starts by itself records whoever is in the room.** The calendar entry does not prove that the people there know about it or
  agree to it. Calendar autostart is only for conversations you would also record by hand, with people who have been told.
- **The law differs from place to place.** In some places every participant must consent. In some places recording a conversation you do not take
  part in is a crime. Employment rules, contracts, confidentiality agreements and data-protection law (for example the GDPR) can apply as well, and
  health, legal and personnel conversations are usually stricter still. This tool cannot tell whether you take part in a conversation or whether
  anybody agreed: it records what the microphone and the system audio carry. This page is not legal advice. You are responsible for finding out
  which rules apply and for telling the people concerned before the recording starts. The general rules of [PRIVACY_AND_CONSENT.md](PRIVACY_AND_CONSENT.md)
  (section 6) apply to every recording this feature starts.
- **Keep the safeguards on.** Keep `NOTIFY_RECORDING=1` (a notification when a recording starts and ends), keep `OFFLINE_REQUIRE_GUESTS=1`, and know
  where **Stop Recording Now** is in the menu. Do not put private conversations (family, friends, a doctor, a lawyer) into the calendar of an account that
  has this switched on. A conversation that is not in the calendar never starts a recording; a cancelled or deleted event is not in the answer at
  all. **An invitation you have not accepted never starts a recording**: anybody can e-mail you a calendar invitation, and Google adds it to your
  calendar by default in many accounts, so an event counts only when you organised it or created it yourself, or you answered **Yes** or **Maybe**.
  An invitation that waits for your answer, one you declined, and one that does not list you at all are left out of the answer before the app sees
  them. (Google Calendar also has a setting for whether invitations are added to your calendar automatically, under Settings, Event settings: setting it
  so that only invitations you answered appear keeps strangers out of the calendar altogether. The wording of that setting is not checked here.)
- **What happens to the recording afterwards is the normal pipeline**: local transcription, then the transcript text goes to Anthropic for the note,
  then the archive folder (see [PRIVACY_AND_CONSENT.md](PRIVACY_AND_CONSENT.md)). For a conversation that must not leave the Mac use the Local-Only
  switch (`LOCAL_ONLY_DEFAULT=1`) or do not record it.
- **Single-user feature.** It is built for the owner of one Mac who carries the laptop to conversations that they put in their own calendar. It is not a feature
  for a fleet of company Macs: the `OFFLINE_*` keys cannot be set by an organisation policy, and an organisation can close the whole thing with the
  `calendar` lane of its policy ([POLICY.md](POLICY.md)).

## 2. What it does

```text
Swift app (OFFLINE_AUTOSTART=auto)  --about once a minute-->  python -m mcap gcal upcoming --from-minutes 15 --to-minutes 3
                                                          |  one JSON object on stdout, exit status 0 always
                                                          v
                                       Google Calendar API, events.list of your primary calendar, read-only
```

The Python side (`pipeline/mcap/gcal.py`) does three things: it signs you in once (`gcal auth`), it answers "which events are around now?" (`gcal
upcoming`), and it forgets the sign-in (`gcal forget`). It never starts a recording and never writes to your calendar. The app decides what to do with
the answer, using the `OFFLINE_*` keys of [CONFIGURATION.md](CONFIGURATION.md#calendar-autostart-offline_). As the app is written at the time of this
change it asks for the window from `OFFLINE_START_AFTER_MINUTES` back to `OFFLINE_START_BEFORE_MINUTES` plus one minute ahead, and it starts a recording
only for an event that is not all-day, not declined, of type `default`, **without a video-conference link unless a room is booked or the location names a place** (a
call is the business of the call detector; see `has_conference` below), with at least one other attendee (`OFFLINE_REQUIRE_GUESTS`), within the length limits, and only while somebody is at the Mac (the idle limit).
Before any of that the Python side drops every event **you do not demonstrably take part in** (`gcal upcoming` leaves it out of `events`): you are its
organizer or creator, or your own attendee entry says `accepted` or `tentative`. `needsAction` (an invitation you never answered), `declined`, an event
whose attendees do not include you, and anything else are dropped. The Swift app therefore never sees an invitation from a stranger.

What the app does around an interruption or another recording (at the time of this change):

- **One start per event.** An event id that was started is remembered in `calendar-autostart.json` (ids and end times only) and is not started again,
  also after a crash or a restart of the app, after a stop by hand (**Stop Recording Now**, **Pause Auto Recording**) and after a stop that the app
  chose itself (the end of the event, no speech for `NO_SPEECH_STOP_MINUTES`, a full disk, the time limit, the organisation policy).
- **A sleep of the Mac or a quit of the app is not a decision.** The recording ends (`sleep` or `app-quit` in `app.log`), and the event is picked up
  again for as long as it runs, up to three times per event: the start window of `OFFLINE_START_AFTER_MINUTES` no longer applies, the idle and lock
  rules still do (a locked screen after the wake waits for the unlock). This is the case "start at the desk, close the lid, walk to the room, open the
  lid": the recording resumes when you are at the Mac again. After a quit, a new run of the app starts the event again only while the start window is
  still open (the app does not keep the interruption across runs). **A crash is not covered**: nothing says that the recording ended, the id stays in
  the file, and the event is not started again.
- **Another recording covers the event.** When an event comes due while a recording of another kind runs (**Start Recording Now**, a Zoom, Teams or
  Meet call), the event is not started, and it is marked as started: when that recording ends, even inside the start window, the app does not start the
  event in its place a minute later. (Back to back: the recording that the app itself started for the first event does not cover the second one.)
- **Errors.** A failed poll (no network, a Google error, a timeout) is tried again after one minute, then every two minutes, so that a Mac that is
  offline around the start still starts the event inside its window. An error that only you can fix (not configured, sign-in needed, policy) is tried
  every 15 minutes. A wake from sleep retries at once.

`gcal upcoming` prints exactly one JSON object and exits with status 0, also when something is wrong (a non-zero status means a crash):

```json
{"schema":1,"ok":true,"now":"2026-10-07T14:00:00+09:00","events":[{"id":"...","title":"...","start":"2026-10-07T14:00:00+09:00",
 "end":"2026-10-07T15:00:00+09:00","all_day":false,"declined":false,"event_type":"default","guests":1,"has_conference":false,"location":""}]}
{"schema":1,"ok":false,"error":"auth_required","message":"Google Calendar is not signed in: run gcal auth"}
```

`event_type` is Google's `eventType` (`default`, `focusTime`, `outOfOffice`, `workingLocation`, `birthday`, `fromGmail`). `guests` is the number of
attendees other than you, resources (rooms) not counted, `0` if there are none. `declined` is true when your own response is "declined" (an invitation
that you declined is left out of `events` altogether; the flag remains for an event that you organise and declined yourself).
`has_conference` is true when the event has a `hangoutLink`, `conferenceData`, or a Zoom, Teams, Meet or Webex link in its location or description,
**and** the people do not sit together: it is false when a room is booked (an attendee that is a resource and did not decline) or the location names a
place (not a URL, no word such as online, virtual, remote, Zoom, Teams, Webex, 화상, 온라인, 비대면, 원격). Google Calendar adds a Meet link to most
invitations whether or not anybody joins it, so a link next to a booked room does not keep an in-person meeting from being recorded. If somebody does
join a call during such a recording it stays one recording: it runs like **Start Recording Now** (platform manual), so the end of the call does not
stop it and no second recording starts.
`all_day` events carry midnight of their day in this Mac's time zone. Cancelled events are left out, and so is every event you do not take part in
(see above: not organizer or creator, and no `accepted` or `tentative` answer of yours).

| `error` | Meaning | What to do |
|---|---|---|
| `not_configured` | `google-oauth-client.json` is missing, not private, or not a Desktop app client | section 3, steps 5 and 6 |
| `auth_required` | not signed in, or Google no longer accepts the saved sign-in | `python -m mcap gcal auth` (see the 7-day rule in step 4) |
| `network` | Google could not be reached (connection, timeout, TLS) | nothing; the next poll tries again |
| `lane_denied` | the `calendar` lane is closed by the organisation policy or by a running pipeline's local-only meeting | ask the administrator, or leave it |
| `policy` | the request was refused before it left (a destination that is not one of the two Google hosts) | a bug: report it |
| `api_error` | Google answered with an error, or something unexpected happened (HTTP status and Google's short reason word are in the message) | `accessNotConfigured` means the Google Calendar API is not enabled in your project (step 3) |

## 3. Setting it up (once; about ten minutes)

Everything below is done by you, in your own Google account. The menu names of the Google Cloud console change from time to time; the names here
are the ones of the Google Auth platform at the time of writing.

1. **Pick the account.** The Google account whose primary calendar holds the conversations. A Google Workspace account of your organisation (your
   administrator may have to allow you to create a project) or a personal Google account.
2. **Create a project.** Open the Google Cloud console (console.cloud.google.com), open the project picker at the top, choose **New project**, give it a
   name such as `meeting-capture-calendar` and, for a Workspace account, the organisation. Make sure the new project is the selected one.
3. **Enable the Google Calendar API.** Menu, **APIs & Services**, **Library**, search for **Google Calendar API**, **Enable**. Without this step every
   request fails with `api_error` and the reason `accessNotConfigured`.
4. **Configure the consent screen.** Menu, **Google Auth platform** (Branding, Audience, Data Access, Clients). Fill in **Branding** (an app name that
   you will recognise, your e-mail address as support and developer contact). Under **Audience** choose the user type:
   - **Internal** if your account belongs to a Google Workspace organisation and you are the only user: nobody outside the organisation can use the
     app, no verification is needed, and the refresh token does not expire after 7 days. This is the better choice whenever it is offered.
   - **External** otherwise (a personal Google account). The publishing status starts as **Testing**: add your own address under **Test users**
     (**Add users**). **In Testing status Google issues refresh tokens that expire after 7 days**, so `auth_required` comes back every week and you run
     `python -m mcap gcal auth` again. To avoid that you can set the status to **In production** (Audience, **Publish app**): the app then stays
     unverified (Google shows an "unverified app" warning on the consent screen, which is acceptable for your own use of your own project).
     Under **Data Access** you may list the scope `https://www.googleapis.com/auth/calendar.readonly` so that the consent screen names it.
5. **Create the OAuth client.** Menu, **Google Auth platform**, **Clients**, **Create client**, application type **Desktop app**, any name, **Create**,
   then **Download JSON**. The file is called `client_secret_<numbers>.json`.
6. **Save it where the pipeline looks for it, private to you.** The file holds a client secret: treat it like a password and never commit it.

   ```bash
   mv ~/Downloads/client_secret_*.json "$HOME/Library/Application Support/MeetingCapture/google-oauth-client.json"
   chmod 600 "$HOME/Library/Application Support/MeetingCapture/google-oauth-client.json"
   ```

   The pipeline refuses the file when it is not a regular file of yours with mode 600 in a folder that only you can write, and it refuses a **Web
   application** client (the file must have an `installed` section). It reads only `client_id` and `client_secret` from it: the addresses inside are
   ignored.
7. **Sign in.** Run `python -m mcap gcal auth` with the pipeline's Python (from the `pipeline` folder:
   `"$HOME/Library/Application Support/MeetingCapture/venv/bin/python" -m mcap gcal auth`). Your browser opens on Google's consent screen (the address is
   printed too; paste it into a browser if nothing opens). Sign in with the account of step 1, press **Continue** on the "Google hasn't verified this app" notice if it
   appears, and allow **read-only** access to your calendar. The browser then shows "Signed in" and the terminal prints the account. The command
   waits five minutes at most.
8. **Check.** `python -m mcap gcal status` shows the client file, the token, the account and the organisation lane, never a secret, and makes no
   request. `python -m mcap gcal upcoming` prints the JSON of section 2 for your real calendar (it contains your event titles: do not paste it anywhere).
9. **Turn it on.** Add `OFFLINE_AUTOSTART=auto` to `~/Library/Application Support/MeetingCapture/config.env`, then quit and reopen the app. The
   other `OFFLINE_*` keys (timing, idle check, minimum number of guests, event length) have defaults; see
   [CONFIGURATION.md](CONFIGURATION.md#calendar-autostart-offline_). `OFFLINE_AUTOSTART=off` (or removing the line) switches it off again.

## 4. What is read, what is sent, what is kept

- **Read.** Events of your **primary** calendar in a window around now (the command's default is 15 minutes back to 30 minutes ahead; the app passes a narrower one; at most 50 events). For
  each event Google is asked for: id, status, title, description, location, event type, conference link and data, start, end, the "this is me" flag of
  the organizer and of the creator (nothing else about them), and for each attendee only the e-mail address, the "this is me" flag, the "this is a
  resource" flag and the response status. The attendee e-mail addresses and the
  description are used in memory to count guests and to find a conference link; they are **not** printed, stored or passed on. The title and the
  location are in the JSON answer for the app, and the Python side writes them nowhere else: no log line, no error message, no file.
- **Written.** Nothing. The scope is exactly `https://www.googleapis.com/auth/calendar.readonly`.
- **Sent, and only to Google.** The sign-in and the reads go **only to Google**: `oauth2.googleapis.com` (client id and secret, the one-time code,
  the refresh token) and `www.googleapis.com` (the access token and the time window). Both over HTTPS, no redirect followed, no proxy or certificate
  variable of your environment honoured, the system trust store. The consent page (`accounts.google.com`) is opened by your browser, not requested by
  the program. **Nothing is sent to Anthropic, to a speech service, to your archive or to anybody else by this feature**; nothing is sent
  to your calendar either.
- **Kept.** The refresh token and the cached access token in your login Keychain, service `MeetingCapture Google Calendar token` (account = your
  user name), written through the `security` tool's standard input so that they are never in a command line, and read back at the moment of use. The
  client file of step 6. No token, secret or event title is written to a log, `state.json`, `usage.jsonl` or the meeting folder by this feature.
- **The organisation lane.** With an organisation policy that denies the `calendar` lane (or locks the Mac, or locks local-only) `gcal` makes no
  request and answers `lane_denied`; your own `CALENDAR_LOOKUP` and `LOCAL_ONLY_DEFAULT` settings concern the other calendar feature and the
  meetings, not this one.

## 5. Revoking, and leaving no trace

1. `OFFLINE_AUTOSTART=off` in `config.env`, restart the app: nothing asks the calendar any more.
2. `python -m mcap gcal forget` deletes the token from the Keychain. It does **not** tell Google.
3. **Remove the grant at Google:** myaccount.google.com/permissions (Security, "Your connections to third-party apps and services"), choose the app name of
   step 4, **Remove access**. Do this whenever you stop using the feature.
4. Delete the client file `~/Library/Application Support/MeetingCapture/google-oauth-client.json`, and in the Google Cloud console delete the OAuth
   client or the whole project if you do not need them.

## 6. What was and was not verified

- The OAuth flow (loopback redirect on `127.0.0.1` with a random port, PKCE S256, `state`, one request and the listener closes), the token requests
  and the `events.list` request follow Google's public documentation (OAuth 2.0 for installed apps, Calendar API reference). The tests use
  document-derived fixtures and in-process stand-ins for Google, the browser and the Keychain tool. **No request has been sent to a real Google
  account and no real Keychain item has been written by the tests or by the author of this change.** The first real `gcal auth` is the real test.
- The Keychain write uses `security -i` with the command on standard input and the data as hexadecimal (`-X`), as the relay token of the company server does
  with `-w`. The line limit of that interactive mode is not verified here; the code leaves the cached access token out of a long command and reads the item back to prove
  it was stored. If `gcal auth` says the token could not be stored, run `python -m mcap gcal status` and report it.
- The rule "you take part" reads the `self` flags of `organizer` and `creator` and the `self` and `responseStatus` of the attendee entries of
  `events.list`, as Google's reference describes them. It is tested against document-derived fixtures only: whether a real account always fills
  these fields for its own events and for invitations, and whether declined events appear in `events.list` at all, is not verified. An event that
  lacks the fields is dropped (the rule fails closed): if one of your own events never starts a recording, run `gcal upcoming` and look for it.
- The resume after a sleep, the cover of another recording and the shorter retry were checked with the app's self tests (a virtual clock, fake
  recorders and a fake command). The behaviour of a real Mac (the lid, App Nap, the lock screen after a wake, the network coming back late) was not
  tried on hardware.
- Google's exact consent-screen wording and the console menus may differ from this page. The 7-day refresh token limit of the Testing status is stated
  in Google's OAuth documentation.
