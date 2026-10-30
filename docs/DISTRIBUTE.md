# Distribute the app as one file (disk image)

Status: **experimental, for anyone who builds this app and shares a copy.** This is not the managed organisation install (`docs/DEPLOY.md`: a signed package, a policy, MDM) and not the developer install (`docs/INSTALL.md`: a checkout and `make install`). The goal is small: a person who receives your copy gets ONE file, `CATE-<version>.dmg`, opens it, drags `CATE.app` (Catch Everything, short name CATE) to Applications, opens the app, and the first launch installs everything else with a guided helper in Terminal. Their guide is [USER_GUIDE.md](USER_GUIDE.md) (English) or [USER_GUIDE.ko.md](USER_GUIDE.ko.md) (Korean), written for people who are not developers. The names in this page and in the guides are the defaults of this source (`Catch Everything`, `CATE`); a build with your own names has your names in its file names and in the app (section 4).

**Before you share a copy: this app records people.** It records the voices of everybody in a call and the microphone of whoever runs it, also when that person is muted, and by default it also records the calls of personal messengers (FaceTime, WhatsApp, Discord, KakaoTalk, ...). Recording people can need their consent, and what is required differs by country and by the rules of an organisation. When you hand the app to somebody you hand them that duty, and you are responsible for what you tell them: read the [legal notice in the README](../README.md#legal-notice-this-tool-records-other-people) and [PRIVACY_AND_CONSENT.md](PRIVACY_AND_CONSENT.md), and keep section 9 of the user guide (telling the participants) in whatever text you pass along. Do not hand the app to somebody who has not been told what it records.

**What has and has not been verified.** Only Zoom has been verified in real calls (the status of the whole project, see the README). Every script of this installer ran only against test doubles (stub `curl`, `hdiutil`, `codesign`, `open`, a fake Python runtime); one build with the real `hdiutil` and `codesign` can be run with `MCAP_TEST_REAL_HDIUTIL=1 scripts/test_scripts.sh`. Nothing has been run on a clean Mac, and the two windows of the app that belong to this feature (the first-run alert and the menu item) have never been looked at in a real session. Section 10 lists what to check yourself before you share the file.

The app is signed with your own self-signed identity and is **not notarized**: macOS shows a warning at the first open (section 8), and the signature tells a stranger nothing about who you are. Whoever downloads the file can only compare its sha256 with the one you publish and has to decide whether to trust you and the place they got it from. What a Developer ID would change is in section 9; nothing in these scripts notarizes, uploads or installs anything.

## 1. The parts

| Part | What it is |
|---|---|
| `scripts/python-runtime.lock` | URL and SHA256 of the Python runtime that goes into the image. Both are `PENDING` in the repository: you fill them once (section 2). |
| `scripts/fetch_python_runtime.sh` | Downloads that runtime into a folder you name, and keeps it only when its sha256 is the one in the lock file. The only script that downloads it. |
| `scripts/build_dmg.sh` (`make dmg`) | Builds the app (`scripts/build_app.sh`), adds the layout of section 4, signs, and creates the disk image. |
| `scripts/first_run_install.sh` | The helper that the app opens in Terminal at the first launch (a copy of it is inside the app). |
| `dmg/README-install.txt` | The ten-line bilingual note that sits in the image next to the app. It is a template: the build fills in the two names of the app, so the note names the file that is really in the image. |
| `app/Sources/FirstRun.swift` | The check ("is everything installed?"), the alert, the menu item "Components: not installed - run installer". |
| `docs/USER_GUIDE.md`, `docs/USER_GUIDE.ko.md` | The guide for the person who installs the app (English and Korean, the same content). |

## 2. Once: the Python runtime

The runtime is a relocatable CPython 3.12 for Apple silicon from the python-build-standalone project (the `install_only` archive of `aarch64-apple-darwin`). It sits inside the app as an archive, so the person who installs the app needs no Homebrew and no Python of their own; the helper unpacks it into `~/Library/Application Support/MeetingCapture/runtime/python` and builds the venv from it.

1. Open the release page of python-build-standalone on GitHub and choose a release that has `cpython-3.12.<patch>+<release>-aarch64-apple-darwin-install_only.tar.gz`.
2. Edit `scripts/python-runtime.lock`: put the address of that file into `URL` (https only) and the sha256 that the release page lists for it into `SHA256`. Nothing in this repository names a release: the address and the checksum are your decision. Until both are filled, `scripts/build_dmg.sh` refuses to build and says `PENDING`.
3. Download it (the folder is the only place the script writes to; `--dry-run` shows the plan first):

```bash
make fetch-runtime ARGS="--out-dir build/runtime --dry-run"
make fetch-runtime ARGS="--out-dir build/runtime"
```

The script runs `curl --proto =https --tlsv1.2 --proto-redir =https`, compares the sha256 of the download with the lock file, refuses a mismatch (the file is deleted), refuses an archive that holds an absolute path, a `..` member or no `python/bin/python3`, and leaves nothing else behind. If you downloaded the archive yourself, `--from-file <archive>` applies the same checks to your copy.

Checked once on the build Mac (2026-10-28, CPython 3.12.15 from release 20261013, a scratch venv outside the app): the packages of `pipeline/requirements.lock.txt` install from a `cp312` hash lock with `pip install --require-hashes --no-deps --only-binary :all:`, and `numpy`, `mlx`, `mlx_whisper` and (with `requirements-silero.txt`) `onnxruntime` import. Not verified: a transcription on 3.12 (the pins were verified on Python 3.13.2) and any of this on a clean Mac. `scripts/setup_python.sh` prints a note about this when it runs with 3.12. Test it (section 7).

## 3. Once: the signing identity

Without a fixed identity the app is signed ad-hoc and macOS asks for the Microphone, System Audio Recording and Notifications permissions again after every update, on every Mac that has your copy. With a fixed self-signed identity (`scripts/make_signing_identity.sh`, run once by you; `docs/INSTALL.md` section 8) the designated requirement stays the same, so permissions survive an update. `scripts/build_dmg.sh` uses exactly the identity that `scripts/build_app.sh` would use: `MC_CODESIGN_IDENTITY`, else the identity named `MeetingCapture Local Signing`, else ad-hoc. `--require-identity` fails instead of falling back to ad-hoc; use it for every build you share. Read the security notes in `docs/INSTALL.md` section 8 first: a self-signed identity and an app without the hardened runtime are a convenience, not a protection.

## 4. Build

```bash
make dmg ARGS="--dry-run"                      # the plan: version, signing, hash lock, layout, what would stop the build
make hash-lock ARGS="--apply --python-tag cp312"   # once per version change: the hash lock for the bundled Python 3.12 (needs the network; build/hash-locks/requirements.lock.hashes.txt)
make dmg ARGS="--require-identity --require-hash-lock --hash-lock build/hash-locks/requirements.lock.hashes.txt"
                                               # build/CATE-<version>.dmg and build/CATE-<version>.dmg.sha256 (the volume is named "Catch Everything")
```

Use `--require-identity` and `--require-hash-lock` for every build you share. Without a hash lock the packages (about 0.55 GB) are installed by version only and **nothing checks their hashes** on the Mac that installs your copy: the plan and the build print that, and `--require-hash-lock` turns it into an error. A hash lock is compared with `pipeline/requirements.lock.txt` at build time (`scripts/setup_python.sh --check-hash-lock`, the comparison the helper's step 3 makes on every Mac): a lock that lists other pins, as after a version bump nobody re-locked, is a build problem, because every helper would stop at step 3 and a re-run could not fix it. Make the lock with `--python-tag cp312`: `scripts/make_hash_lock.sh` writes the hashes of the wheels for the tag (default `cp313`), and the bundled runtime is 3.12, so a `cp313` lock lists wheels that Python would never pick. A hash lock made for `cp312` installed with the bundled runtime on the build Mac (section 2); not verified on a clean Mac.

**The bundle identifier and the names.** Three build inputs say what your copy is: `MCAP_BUNDLE_ID` sets the app's identifier (`CFBundleIdentifier`, the code-signing identifier, the login-agent label), `MCAP_APP_NAME` the human name (default `Catch Everything`: the display name, every message of the app and the volume name of the disk image) and `MCAP_APP_SHORT_NAME` the file-safe short name (default `CATE`: `CATE.app`, its program and `CATE-<version>.dmg`). The defaults, `org.meetingcapture.app`, `Catch Everything` and `CATE`, are shared by every copy built from this source, so they name nobody. A distributor who ships their own build sets their own id and names, for example:

```bash
MCAP_BUNDLE_ID=com.example.mcap-test MCAP_APP_NAME="Example Recorder" MCAP_APP_SHORT_NAME=ExampleRecorder \
  make dmg ARGS="--require-identity --require-hash-lock --hash-lock build/hash-locks/requirements.lock.hashes.txt"
                                               # build/ExampleRecorder-<version>.dmg, build/ExampleRecorder-<version>.dmg.sha256, the volume "Example Recorder"
```

and keeps using the same three values for every later build: to macOS a different id is a different app, which asks for the Microphone, System Audio Recording and Notifications permissions again (see `CONTRIBUTING.md`, "Forks that distribute builds"), and a different short name is another app file next to the old one on every Mac that has your copy. A value that breaks the rules (`docs/CONFIGURATION.md`, "Names and identifier of the app") is refused before anything is built; the app, the scripts and the helper read the names back from the built app, so one build has one set of names. What the three inputs name, in the image: the disk image `<short name>-<version>.dmg` and its checksum file `<short name>-<version>.dmg.sha256`, the volume `<human name>`, the app `<short name>.app` and `README-install.txt`, which carries both names. What they do not rename: the data folder, the log folder and the Keychain items keep the internal name `MeetingCapture` (they are paths and identifiers, and a new name would orphan what is already on a Mac). The guides in this repository say `Catch Everything` and `CATE.app`; for a build with your own names, change the names in the guide text you pass along.

Set `MCAP_BUILT_BY="Your Name, example.org"` to put a builder line into the About panel (`docs/BRANDING.md`); it passes through to the app inside the image, so everybody who gets the file sees it. The version is the `VERSION` file (or `MCAP_VERSION`), the same one `scripts/build_app.sh` writes into the app; change it, `CHANGELOG.md` and `pipeline/mcap/__init__.py` together before you build for others. The last line on stdout is `<sha256>  <path of the dmg>`.

What the script does, in order: it refuses a `PENDING` lock file, a missing runtime and a runtime whose sha256 is not the one of the lock; it builds the app and copies it to `build/dmg-stage/` (the plain `build/CATE.app` stays a plain build); it adds the layout below BEFORE signing; it signs every nested Mach-O file and then the app with the same identity, without the hardened runtime, and verifies the signature; it creates the image with `hdiutil` (UDZO, volume name = the human name of the app, `Catch Everything` by default, an `/Applications` link, `README-install.txt` with the two names filled in) and prints the sha256. `--hash-lock <file>` also puts a hash lock of the Python packages into the app (made by `scripts/make_hash_lock.sh`); the helper then installs with `pip install --require-hashes --no-deps`.

The layout inside `CATE.app/Contents/Resources`:

```
mcap/pipeline/mcap/                   the Python package (no tests, no bytecode) and pipeline/requirements*.txt
mcap/config/                          note_prompt.md, cleanup_prompt.md, verify_prompt.md, vocabulary.txt, config.env.example
mcap/scripts/                         setup_python.sh, first_run_install.sh, legal_notice.sh, bundle_id.sh (the helpers read the names of the app from it)
mcap/VERSION
mcap/components.json                  {"python_runtime":{"file":"../runtime/python-runtime.tar.gz","sha256":"..."},"requirements_lock_sha256":"..."}
runtime/python-runtime.tar.gz         the Python runtime of section 2
```

Besides the files above, `--hash-lock` adds `mcap/pipeline/requirements.hash-lock.txt`, and the helper keeps its lock `~/Library/Application Support/MeetingCapture/.first-run.lock` (a link that names the pid of the running helper) while it runs.

The app finds its pipeline there: the project folder is `Contents/Resources/mcap` when that folder exists, and a `PROJECT_DIR` in `config.env` still wins (`app/Sources/Config.swift`). The Python side needs no variable for the prompts: it also looks for `config/` next to the package it runs from (`pipeline/mcap/note.py`), and the helper copies the example vocabulary to `SUPPORT_DIR` (the app's `setup` wants it there). There is no compiled code in the bundle apart from the app binary (the runtime is an archive until the helper unpacks it), so "every nested Mach-O file" is normally none; the script still looks for them and signs them first.

## 5. What the first launch does

1. The app starts and checks, in the background and without a network, whether `~/Library/Application Support/MeetingCapture/components-installed.json` exists and has the hashes of the app's `components.json`, and whether the venv python and the pinned model files are in place. A build without `components.json` (from source, the organisation package) never checks or asks anything.
2. **Until the helper has finished, the app records nothing.** The recording legal notice is step 1 of the helper (and the macOS permissions and the notifications are asked in its step 7), so an app without `components-installed.json` must not record: it detects no call, "Start Recording Now" is off, the calendar auto-start is refused, and the first line of the menu says "Auto recording is off until the installer has finished". The verdict is read before the controller starts (a few file reads), and the check repeats every ten seconds while the hold lasts, so the hold ends by itself shortly after the helper has written its record (no restart needed). An older record (an update is needed, a model or the venv is missing) does not hold: the notice was accepted before. A recording that already runs is never ended by it. This is a guard against recording before the notice, not a security boundary: the record is a plain file.
3. If something is missing it shows ONE alert per launch: "Catch Everything needs to install its components (about 4 GB download, needs internet). Start now?" (the human name of the build stands in front) with **Start** and **Later** (Korean when `UI_LANGUAGE=ko`; at the very first launch there is no `config.env` yet, so a Mac whose first language is Korean gets the Korean alert). It never shows it on a policy-managed Mac, and not when the app was not started by LaunchServices. **Later** leaves the menu item "Components: not installed - run installer".
4. **Start** copies `scripts/first_run_install.sh` to `SUPPORT_DIR/first-run-install.command` (so a moved or deleted app does not matter), writes `SUPPORT_DIR/first-run.env` (one line: the app's `mcap` folder) and opens the copy in Terminal.
5. The helper shows the recording legal notice (type yes), checks the Mac (Apple silicon, macOS 14.4 or newer, 12 GB free, the package index and the model host answer), unpacks the runtime after its sha256 matches `components.json`, runs `scripts/setup_python.sh` with it (venv from the pinned requirements, the Silero model, the speech model at its pinned revision, every hash check of that script unchanged), offers to store the Anthropic API key (first it only asks whether a Keychain item exists, without reading the value; the macOS `security` tool asks for the key, hidden; the key never passes through the helper), writes `config.env` only when there is none, asks (y/n) about a Google Drive folder when exactly one account is mounted, runs the app's own `setup` so macOS asks for the permissions, and writes `components-installed.json`. Each step prints `[n/7]`; a failure prints the step, the likely cause and "run this script again: it resumes".
6. Only one helper window runs at a time. At the start of step 2 it takes the lock `.first-run.lock`; a second window (two clicks on the menu item, or the alert and the menu item) stops there with "Another installer window is already running", changes nothing and says what to do; the app does not open a second window while the lock is held and shows a notice instead. A lock of a process that has ended, or of a pid that is not the helper, is ignored.
7. Python writes bytecode next to the sources it imports; inside a signed app that would change the sealed bundle. The helper therefore adds a `.pth` file to the venv that sends the bytecode to `~/Library/Caches/MeetingCapture/pycache`.

If the app is opened from the disk image or from a translocated copy (`/Volumes/...`, `AppTranslocation`), it does not install; it asks the person to drag it to Applications first, because components installed for a copy that macOS may remove would point at a place that disappears.

## 6. Share it

Any file host works; this repository does not pick one for you and uploads nothing. Two usual choices:

- **A GitHub release** on your own repository or fork: anybody who finds it can download the file. See "Publishing a release on GitHub" below.
- **A cloud drive link** (any provider) with access limited to the people you choose, not "anyone with the link" unless you really want everybody to have it.

1. Upload `CATE-<version>.dmg` and `CATE-<version>.dmg.sha256` to the host you chose. The file holds the app and a Python runtime, no key and no recording; check that your `MCAP_BUILT_BY` text is something you want everybody who gets the file to see.
2. Point people to the user guide ([USER_GUIDE.md](USER_GUIDE.md), or [USER_GUIDE.ko.md](USER_GUIDE.ko.md); or paste its text into your own page) and tell them where they can ask you. The guide sends people with a question to "the person who sent you this file, or the project page you got it from", so make sure that is true for your copy.
3. Whoever wants to check the download: `shasum -a 256 CATE-<version>.dmg` must print the checksum from the `.sha256` file. A download from a browser carries the quarantine flag, which is what makes macOS show the Gatekeeper warning of section 8.

### Publishing a release on GitHub

Nothing in this repository publishes a release for you: no script, `make` target or workflow builds the disk image in CI or uploads it (`docs/RELEASING.md` describes the project's own release, which is the source and an ad-hoc app zip without a Python runtime, never this image). If you decide to publish your build, do it by hand on the GitHub page of your own repository or fork, after the test of section 7, and read the draft before you press Publish.

1. Upload the disk image `CATE-<version>.dmg` and the checksum file `CATE-<version>.dmg.sha256` (the last line the build printed is the same number).
2. Also upload `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES.md`: the image holds none of them, and the Apache-2.0 licence of the app asks that people who get it also get the licence and the NOTICE. The image also carries a Python runtime from the python-build-standalone project, which `THIRD_PARTY_NOTICES.md` does not list: read the licence files that belong to the archive you pinned in section 2 and add what they require. This repository has not checked that for you.
3. Paste the sha256 into the release notes, so it is on the page next to the file and people can compare it with `shasum -a 256 CATE-<version>.dmg`.
4. Say in the notes, in plain words: the app is self-signed and **not notarized** (macOS shows a warning at the first open, section 8), it needs an Apple silicon Mac with macOS 14.4 or newer and about 4 GB of downloads at the first start, only Zoom calls have been verified in real use, and it has not been run on a clean Mac (change these lines only when you have tested more).
5. Put the warning about recording people at the top of the notes (the first paragraph of this page, in your words), and link the user guide with the address of the page in your repository: `docs/USER_GUIDE.md` and `docs/USER_GUIDE.ko.md`.
6. Do not say or link, in a README or anywhere else, that a download exists before you have published it. The READMEs of this repository do not claim one.

## 7. Test it on a second Mac before you share it

On a Mac (or a new macOS user account) that has never run the app and has no developer tools:

- Download the dmg through the link or release page you will really use, in a browser, open it, drag the app to Applications, open it (section 8).
- The alert appears; **Start** opens Terminal; every step of the helper runs to the end on a normal home connection; the macOS prompts for the Microphone, System Audio Recording and Notifications appear and can be answered.
- Run `~/Library/Application Support/MeetingCapture/venv/bin/python -m mcap doctor` from `Contents/Resources/mcap/pipeline` of the app, and place one short Zoom test call alone (`docs/LIVE_TEST.md`): the recording starts, the transcript is made, the note is made when a key is stored.
- Quit and open the app again: no alert, no "Components" item. (This also proves the model check: the speech model file in the Hugging Face cache is a link into `blobs/`, and the app follows it.) Then delete `components-installed.json` and open it again: the alert comes back. With the alert open, start a short test call: nothing is recorded, the first line of the menu says "Auto recording is off until the installer has finished" and "Start Recording Now" is off. Answer **Start** and let the helper finish: within about ten seconds the line goes away without a restart, and a test call is recorded.
- The alert while recording is allowed: delete only `~/Library/Application Support/MeetingCapture/models/silero_vad.onnx` and open the app. The alert comes back; leave it open and start a Zoom test call: the menu bar icon turns red and the start notification arrives (the alert is shown from the run loop, not from inside a main-queue block, so nothing waits for your answer). Put the model back with the helper afterwards.
- Click "Components: ... run installer" twice in a row: one Terminal window opens, the second click says that the installer is already running.
- Replace the app with a newer build: the permissions still work (fixed identity), and an updated runtime or lock offers the installer again ("update needed").

## 8. What Gatekeeper shows, and what to tell people

The app is not notarized, so the first open is blocked by Gatekeeper. The documented ways, which the guides and `README-install.txt` tell people:

- Control-click (right-click) the app, choose **Open**, then **Open** in the dialog. This is enough on macOS 14.
- On recent macOS (15 and later) the dialog may offer no Open button for an app like this. Then open the app once, close the dialog, go to **System Settings > Privacy & Security**, scroll to the message about Catch Everything and click **Open Anyway**; macOS asks for a password or Touch ID.

Not verified: the exact wording and the exact steps on each macOS version; they were taken from Apple's documented behaviour, not observed here. Check them on your second Mac and correct the guides.

## 9. Apple Developer ID (not done here)

With a paid Apple Developer account the same layout can be signed with a Developer ID certificate, with the hardened runtime, and notarized, which removes the warning of section 8. That is work for whoever builds the app and holds the account; this repository does not do it: `scripts/build_pkg.sh` prints the `xcrun notarytool` and `stapler` commands for the organisation package and runs none of them, and `scripts/build_dmg.sh` does not notarize. Expect to change: the signing arguments of `scripts/build_app.sh` and `scripts/build_dmg.sh` (the hardened runtime needs entitlements for the microphone and audio input), sign and notarize the disk image itself, and accept that the designated requirement changes once, so macOS asks everybody who has the app installed for the permissions one more time.

## 10. Not verified, and limits

- Only Zoom has been verified in real calls. Teams, Google Meet and the other call apps have not.
- Nothing of this feature has run on a clean Mac: not the Gatekeeper steps, not the helper end to end, not the first-run alert, not the menu item, not the start of Terminal through the macOS `open` command (all AppKit and `open` calls ran only as test doubles).
- The packages were pinned on Python 3.13.2. On the bundled 3.12 they install from the hash lock and import (section 2), but no transcription has been run on 3.12 yet.
- The recording hold, the one-helper lock and the alert from the run loop are tested as pure functions and against fakes (the lock with real shell processes); nobody has seen them in a real session, with a real Terminal or with a real second click.
- The disk image has no custom background or icon layout, and the image itself is not signed (a self-signed signature on it would prove nothing).
- Packages are installed with the pinned versions of `pipeline/requirements.lock.txt` unless you pass `--hash-lock` (a build without one warns; `--require-hash-lock` refuses it); the speech model and the Silero model are checked against pinned sha256 values by `scripts/setup_python.sh` either way.
- The helper needs the Claude Code tool (`claude`) only for meeting notes and does not install it; without it, or without a key, audio and transcripts still work.
- A Mac with this install is not managed: no policy, no remote switch. Its settings are the ones in `config.env` (Settings window).
- The licence texts of the bundled Python runtime are not part of `THIRD_PARTY_NOTICES.md` and the image carries no `LICENSE` or `NOTICE` (section 6, "Publishing a release on GitHub").
