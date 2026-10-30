# Install guide

Catch Everything (short name CATE) is built from source on your own Mac. Nothing here needs an Apple Developer account, Xcode or a prebuilt binary: you compile the app yourself with `swiftc` from the Xcode Command Line Tools. (Releases may also carry an ad-hoc signed app zip, see section 8. Building from source stays the recommended path, because the app runs `pipeline/` from your clone anyway.) The scripts that change your system (`scripts/install.sh`, `scripts/uninstall.sh`, `scripts/setup_python.sh`, `scripts/make_launchagent.sh`, `scripts/make_signing_identity.sh`) accept `--dry-run` and are safe to run again; none of them overwrites a settings file you edited. `scripts/build_app.sh` only builds, and `make hash-lock` prints a plan unless you add `--apply`.

Read the [legal notice in the README](../README.md#legal-notice-this-tool-records-other-people) before you install. After installation the app can record every call you join.

Korean speakers: the same steps are summarised in [README.ko.md](../README.ko.md).

People who should not build from source can use one disk image that somebody who builds the app hands them: [DISTRIBUTE.md](DISTRIBUTE.md) (build, sign, share, test) and, for the person who installs it, the user guide ([USER_GUIDE.md](USER_GUIDE.md), Korean: [USER_GUIDE.ko.md](USER_GUIDE.ko.md)). The app in the image installs its own Python environment and models at the first launch with a guided helper in Terminal; the rest of this guide is for installs from a checkout.

## 1. What you need

| Need | Check |
|---|---|
| Apple silicon (M1 or newer), **16 GB of RAM or more recommended** | `uname -m` prints `arm64` (a Rosetta shell prints `x86_64`: open a normal Terminal). The speech model takes about 4 GB of memory while a meeting is transcribed, next to the call itself |
| macOS 14.4 or later | `sw_vers -productVersion` |
| Xcode Command Line Tools | `xcode-select -p` prints a path; if not, run `xcode-select --install` |
| Python 3.12 or 3.13 (required) | The pinned numpy and scipy need 3.12 or newer, so 3.11 and the `python3` that comes with macOS or the Command Line Tools do not work. `scripts/setup_python.sh` looks for `python3.13`, then `python3.12`, in `/opt/homebrew/bin`, the python.org framework, `/usr/local/bin` and on your `PATH`. Install one yourself: with Homebrew `brew install python@3.13`, or without Homebrew the macOS installer from [python.org](https://www.python.org/downloads/macos/), then pass `MCAP_PYTHON=/Library/Frameworks/Python.framework/Versions/3.13/bin/python3.13` if the script does not find it. The scripts never install Python or Homebrew packages. |
| Claude access, for the notes | an Anthropic API key (recommended) or a logged-in Claude subscription, and the `claude` tool installed from [Anthropic's documentation](https://code.claude.com/docs/en/overview) |
| Disk | about 0.55 GB Python environment, 3.08 GB speech model, 0.7 GB temporary audio per hour of meeting |
| Network | PyPI, Hugging Face and raw.githubusercontent.com during the install; Anthropic when notes are written |

The Python packages are pinned by version in `pipeline/requirements.lock.txt` and are installed with `pip --no-deps`, so `torch` is never pulled in. Do not run a plain `pip install mlx-whisper`. The pins are not hash-checked unless you use the optional hash lock (section 9).

## 2. Get the source

```bash
# the clone address is the HTTPS address shown on this repository's page
git clone <repository-url> meeting-capture
cd meeting-capture
```

Use `git clone` rather than a browser download of a ZIP: files from a browser carry macOS's quarantine flag. If you did download a ZIP, check its checksum and then remove the flag with `xattr -dr com.apple.quarantine <folder>`. (The quarantine behaviour is described from general macOS knowledge; it was not tested on a clean machine for this guide.)

Keep the folder where it is. The app runs `pipeline/` and the prompts from it, and `config.env` stores its path as `PROJECT_DIR`. If you move it, edit `PROJECT_DIR` and run the install again.

## 3. Plan, then install

```bash
make install ARGS="--dry-run --python --with-silero --pre-download-model"
make install ARGS="--python --with-silero --pre-download-model"
```

The first command prints every action and the exact download sizes and changes nothing. The second does the work. Before it creates anything it shows the **recording legal notice** (the same text as the README) and asks you to type `yes`. Without a terminal (CI, a plain `ssh` command) the install refuses unless you accept the notice explicitly with `--accept-legal-notice` (`make install ARGS="--accept-legal-notice --python"`); `--dry-run` shows the notice and asks nothing.

1. creates `~/Library/Application Support/MeetingCapture` (settings, sessions, Python environment, models) and `~/Library/Logs/MeetingCapture`;
2. copies `config.env` and `vocabulary.txt` there **only if they are missing**. An existing file is kept; if the repository version differs you get a `diff` hint. `config/note_prompt.md` is not copied: the pipeline reads it from the repository unless you create `note_prompt.md` in the support folder to override it;
3. builds the app with `swiftc`, signs it (ad-hoc unless you created the identity of section 8) and installs it to `~/Applications/CATE.app` (`~/Applications/<short name>.app`: the file name is the short name, below);
4. with `--python`: creates the Python environment from the lock file. `--with-silero` adds the Silero voice-activity model (25 MB, sha256-verified; without it an energy-based detector is used, which mistakes noise for speech more easily). `--pre-download-model` downloads the 3.08 GB Whisper model now instead of during your first meeting;
5. writes the login agent **only after you confirmed the live test yourself** (section 6), and never loads it unless you pass `--load`;
6. prints the next steps.

Options of `scripts/install.sh` (pass them through `ARGS`):

| Option | Effect |
|---|---|
| `--dry-run` | print everything, change nothing |
| `--accept-legal-notice` | accept the recording legal notice without being asked (needed when there is no terminal) |
| `--python` | also build the Python environment (needed for transcription) |
| `--with-silero`, `--pre-download-model` | imply `--python`; see above |
| `--require-signing` | stop before changing anything if the fixed signing identity (section 8) does not exist |
| `--no-build` | reuse the installed app |
| `--no-launchagent` | do not touch the login agent at all |
| `--load` | load the login agent now; refused until the live test is confirmed |
| `--with-qwen-bench` | also build a separate benchmark environment; not needed for normal use |

The app and the login agent carry the bundle identifier `org.meetingcapture.app` unless you set `MCAP_BUNDLE_ID` to a reverse-DNS id of your own when you build (`MCAP_BUNDLE_ID=com.example.mcap-test make install ...`). Use the same id on every build: macOS ties the permissions to it, so a stable id keeps them across updates and a different one is a different app that asks again; `make install` refuses to replace an installed app that has another id unless you set `MCAP_ALLOW_ID_CHANGE=1` ([CONTRIBUTING.md](../CONTRIBUTING.md#forks-that-distribute-builds), [CONFIGURATION.md](CONFIGURATION.md)). For a build you run on your own Mac there is nothing to change.

**Names of the app.** Two more build inputs, set the same way, name the app: `MCAP_APP_NAME`, the human name (default `Catch Everything`: the display name, the texts of the app, the volume of the disk image), and `MCAP_APP_SHORT_NAME`, the file-safe short name (default `CATE`: the file `CATE.app`, its program, `CATE-<version>.dmg`). A value that breaks the rules is refused before anything is built; the rules, how the scripts find the names again and what keeps its internal name `MeetingCapture` (the data folder, the log folder, the Keychain items) are in [CONFIGURATION.md](CONFIGURATION.md#names-and-identifier-of-the-app). To keep the names of a build you already run, set `MCAP_APP_NAME` and `MCAP_APP_SHORT_NAME` to what the installed app already uses: an app file with another name next to the new one, with the same bundle id, is refused by the install guard (two apps with one id would share one login agent and one set of permissions). The commands in this guide say `CATE.app`; use your own file name if you built with another short name.

**Optional branding.** The menu-bar menu has an **About Catch Everything** item (version only; it carries the human name of the build). An internal build can also name who built it: `MCAP_BUILT_BY="Example Team, example.org" make install ARGS="--python --with-silero --pre-download-model"` adds that line to the About panel and to the app's `Info.plist`; without the variable the app names nobody, and the sources never contain a name. The same page, [docs/BRANDING.md](BRANDING.md), shows how to preview and change the app icon (`scripts/make_icon.swift`: three notes-and-pen variants and the three former waveform variants) and which menu-bar symbols the app uses.

`--python` here is a switch: in `make install ARGS="--python ..."` it never takes a path. To choose the interpreter, put `MCAP_PYTHON` in front: `MCAP_PYTHON=/path/to/python3.13 make install ARGS="--python --with-silero --pre-download-model"`, or run `scripts/setup_python.sh --python /path/to/python3.13` directly (there the option takes a path).

## 4. Settings and Claude access

Open `~/Library/Application Support/MeetingCapture/config.env` (`open -e` works). Review at least `ARCHIVE_DIR` (any folder; a Google Drive folder is `~/Library/CloudStorage/GoogleDrive-<your-account>/My Drive/Meetings`), `SELF_NAME`, `CLAUDE_AUTH`, `CALENDAR_LOOKUP` (the example ships `0`: no calendar lookup) and `LOG_CONTENT`. Every key is explained in [config/config.env.example](../config/config.env.example).

- **API key mode** (`CLAUDE_AUTH=api`, the default and the supported path): run `make set-api-key` once in a Terminal. The macOS `security` tool asks for the key; it goes into your Keychain and nowhere else. Check it with `cd pipeline && "$HOME/Library/Application Support/MeetingCapture/venv/bin/python" -m mcap api-key check` (one tiny call). In the Anthropic Console, use a key made for this project and give it a monthly spend limit. `CLAUDE_DAILY_BUDGET_USD` and `CLAUDE_MEETING_BUDGET_USD` (5 and 2 USD) are extra brakes inside the tool.
- **Subscription mode** (opt-in, `CLAUDE_AUTH=subscription`): run `claude auth login`. This tool runs `claude -p` in the background without you at the keyboard, so **check Anthropic's terms for your account first**; the [Anthropic section of the README](../README.md#anthropic-and-claude) explains why.
- `CLAUDE_BIN` defaults to `~/.local/bin/claude`. If `command -v claude` shows another location, put it in `config.env`.

**Or use the Settings window.** After the app runs, the menu-bar item **Settings…** (Cmd-,) edits the keys above and the other common ones (language, platforms, call apps, Local-Only, the cloud speech engines) and can store the API key in the Keychain (**Save key**, **Check key**). It keeps your comments and your other lines, writes a backup first, and shows what leaves the Mac under the saved settings; see [SETTINGS.md](SETTINGS.md). The consent to a cloud speech engine and the Google sign-in stay Terminal commands (the window opens Terminal for you).

Then run `make doctor`. It checks the configuration, the Python environment, the model cache, the Claude key or login and the archive folder.

## 5. Permissions

macOS ties permissions to the app itself, so they must be granted to `CATE.app`, not to Terminal. That is why the commands use `open -n -W -a` (`-n` is required: without it a running menu-bar app only gets re-activated and the arguments are ignored). Running the binary from a shell is refused.

```bash
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args setup
```

The checklist prints `[ OK ]`, `[WARN]` and `[FAIL]` lines and the prompts appear one after the other. Allow all of them.

| Permission | Why | If you refuse |
|---|---|---|
| Microphone | your own voice | your side is not recorded |
| System Audio Recording | the other participants. This is not a screen-recording permission and the app records no video | the remote track is **silent without any error** (the app notifies you) |
| Access to the archive folder | writing finished meetings (needed for locations such as Google Drive or Documents) | publishing fails and the meeting stays in the staging folder |
| Notifications | recording started or ended, note ready, silent remote track, failures | messages only appear in the log and the menu |
| Login items (background item) | only when you turn on the login agent | no automatic start |
| Chrome Automation | only if you enable Google Meet detection | not asked while Meet is off |

The exact pane names change between macOS versions; System Audio Recording sits under System Settings > Privacy & Security > Screen & System Audio Recording.

## 6. Test it, then turn on automatic start

```bash
# device test, about 15 seconds: records both tracks for real and prints the levels. It plays a short sound: not during a real meeting.
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args selftest-capture --live --seconds 12 --out "$HOME/mcap-selftest"

# start the app by hand, then try a Zoom call alone ("New Meeting") and a Teams call alone ("Meet now")
open ~/Applications/CATE.app
```

Follow [LIVE_TEST.en.md](LIVE_TEST.en.md) (English) for the expected results of each step; the longer checklist [LIVE_TEST.md](LIVE_TEST.md) is written in Korean and starts with an English summary of every section. When the setup report has no `[FAIL]`, the device test says PASS and the solo calls produced a transcript and a note:

```bash
make confirm-live-tested                 # shows the recording legal notice again; you type yes and then 'confirmed'; needs a terminal
scripts/make_launchagent.sh --load       # writes ~/Library/LaunchAgents/<label>.plist and loads it
```

This gate is deliberate: a written login agent starts the app at every login and from then on records every Zoom and Teams call, and every call of the other call apps of the built-in table (Slack huddles, Webex, Discord, FaceTime, KakaoTalk, WhatsApp and a few more; `CALL_DETECT=known` is the default, `CALL_DETECT=off` switches them off, `CALL_DETECT=generic` would also guess apps nobody named). There is no option to skip it. `make confirm-live-tested` refuses while the setup report has a `[FAIL]` line. On a personal install a missing or logged-out `claude` tool is only a `[WARN]` (audio and transcripts do not need it), so it does not block this step. If you do not want meeting notes at all, set `LOCAL_ONLY_DEFAULT=1` in `config.env` and run `setup` again: every new meeting then starts Local-Only (audio and transcripts only) and a missing API key item is a `[WARN]` too. macOS may show a "background item added" notification; System Settings > General > Login Items shows whether Catch Everything is enabled. **Quit** in the menu stops the app and it stays stopped; a crash is restarted after 30 seconds. To stop the agent: `scripts/make_launchagent.sh --unload`.

## 7. Updating

```bash
git pull
make install ARGS="--python --with-silero --pre-download-model"
```

Your `config.env`, `vocabulary.txt`, sessions and models are kept (a `diff` hint shows when the repository copy of a settings file changed; new keys can simply be added). The Python environment is left alone when its packages already match the pins. An ad-hoc signed build has a new code hash, so macOS asks for the permissions again after a rebuild; the fixed identity of the next section avoids that. Quit and reopen the app, or `scripts/make_launchagent.sh --load`, to run the new build.

**An app installed by an earlier version of this source.** Builds made before the names became build inputs have the app file `MeetingCapture.app`. The new default file is `CATE.app` with the same bundle id (unless you set `MCAP_BUNDLE_ID` for one of the two builds), so `make install` refuses to put it next to the old file: two apps with one id would share one login agent and one set of permissions. Choose one way. Keep the names you run: set `MCAP_APP_NAME` and `MCAP_APP_SHORT_NAME` to what the installed app already uses (`CFBundleDisplayName` and `CFBundleName` in its `Info.plist`) when you build, and nothing about the app file changes. Or switch to the new names: quit the app, remove the old one (`MCAP_APP_SHORT_NAME=<its file name without .app> scripts/uninstall.sh` removes the login agent and that app and keeps your settings, sessions, models and logs; without the variable the script names the old file and does not delete it), then run `make install` again. The live-test confirmation is removed with the old install, so confirm it again (section 6) before you load the login agent. Until you have chosen, `scripts/make_launchagent.sh` writes the login agent for the one app in `~/Applications` that has the bundle id when `CATE.app` is not there (it says so); with two such apps it does not guess (it warns, and `--load` stops): set `MCAP_APP_SHORT_NAME` or pass `--app`.

An install from the disk image (DISTRIBUTE.md) is updated by replacing the app with a newer one; the app offers its installer again when the Python runtime or the requirements of the new version differ from what is installed.

## 8. Optional: a fixed signing identity

With the default ad-hoc signature, macOS identifies the app by its code hash, so every changed build asks for Microphone, System Audio Recording and Notifications again. A fixed, self-signed identity in your login keychain makes the permissions survive rebuilds. **You run this yourself, once.**

```bash
scripts/make_signing_identity.sh --dry-run    # look first: proves openssl works, only reads the keychain
scripts/make_signing_identity.sh              # create it; an existing identity is kept
```

What it does: openssl creates a certificate named `MeetingCapture Local Signing` (2048-bit RSA, code signing, valid 10 years; the certificate keeps this name because it is not the name of the app, and an identity you made earlier is still found by it) in a private temporary folder; `security import` puts it into your login keychain so that only `/usr/bin/codesign` may use the key without asking; it signs a temporary copy of `/usr/bin/true` as a self-test and prints the designated requirement. macOS may show its own dialogs (unlock the keychain, "codesign wants to sign using key"). Type your login password into those macOS dialogs and choose "Always Allow". The script never asks for, reads or stores your password.

If `codesign` refuses the self-signed certificate (the script exits with code 3), it prints the follow-up and you decide: `scripts/make_signing_identity.sh --trust` runs `security add-trusted-cert` for your user account only, for this one certificate and only for code signing.

**The trade-off, read it before you run it:**

- the private key is in your login keychain and `/usr/bin/codesign` may use it without a prompt, so any process running as you can sign code with this identity;
- code signed with it has the same designated requirement as `CATE.app`, so it inherits the permissions you granted the app (microphone, system audio, and so on);
- the app is signed without the hardened runtime, so a process running as you can inject a library into it.

On a one-person Mac that is the price of not re-approving permissions after every rebuild. If you do not want it, stay with ad-hoc signing, which has none of these risks.

After creating the identity, rebuild so the app is signed with it, and grant the permissions once more (the permissions of an ad-hoc build do not move over):

```bash
make clean build
make install ARGS="--require-signing --python"
open -n -W -a ~/Applications/CATE.app --stdout "$(tty)" --stderr "$(tty)" --args setup
```

Remove the identity again at any time (certificate, private key and trust setting):

```bash
security delete-identity -c "MeetingCapture Local Signing" -t ~/Library/Keychains/login.keychain-db
```

The app is not notarized. That is normal for a build you made yourself, which macOS does not quarantine, so it needs no Gatekeeper step. A prebuilt ad-hoc zip from a GitHub release is different: a browser download is quarantined and macOS refuses an app that is not notarized. Follow the steps in that release's notes (check `shasum -a 256 -c SHA256SUMS` first, then open it through System Settings > Privacy & Security > Open Anyway, or remove the flag with `xattr -dr com.apple.quarantine CATE.app`). The app still needs this repository next to it, because it runs `pipeline/` from `PROJECT_DIR`. Notarizing requires an Apple Developer Program account; `scripts/build_pkg.sh` (organisation mode, see [docs/DEPLOY.md](DEPLOY.md)) prints the commands but nothing in this repository runs them.

## 9. Optional: hash-pinned packages

By default the packages are version-pinned but not hash-checked. For a hash-pinned install, `make hash-lock` prints a plan (it fetches nothing); with `ARGS=--apply` it asks pypi.org for the hashes of every pinned wheel and writes `build/hash-locks/requirements.lock.hashes.txt`. Review that file, then build the environment from it:

```bash
make hash-lock
make hash-lock ARGS=--apply
scripts/setup_python.sh --hash-lock build/hash-locks/requirements.lock.hashes.txt --recreate
```

The hashes are collected for the wheels of Python 3.13 (`cp313`). If your environment uses Python 3.12, ask for its wheels instead: `make hash-lock ARGS="--apply --python-tag cp312"`.

## 10. Uninstall

```bash
scripts/uninstall.sh --dry-run     # look first
scripts/uninstall.sh               # unloads and deletes the login agent, deletes the app; keeps settings, sessions, venv, models, logs
scripts/uninstall.sh --purge       # also deletes the support folder (including recordings that were not published yet) and the logs
```

`--purge` shows what would be deleted, including the names of unpublished recording folders, and changes nothing until you type `purge`. Reinstalling also requires confirming the live test again.

Never touched by the script, so clean up by hand if you want:

| What | How |
|---|---|
| Your meetings | the `ARCHIVE_DIR` folder (your data) |
| macOS permissions | `tccutil reset All "$(defaults read ~/Applications/CATE.app/Contents/Info CFBundleIdentifier)"` **before** you uninstall (it needs the app's Info.plist), then remove leftovers in System Settings > Privacy & Security |
| API key in the Keychain | `cd pipeline && "$HOME/Library/Application Support/MeetingCapture/venv/bin/python" -m mcap api-key forget --yes` before you purge the support folder |
| Signing identity | the `security delete-identity` command of section 8 |
| Speech model cache | `~/Library/Application Support/MeetingCapture/models` is removed by `--purge`; the Hugging Face cache is `~/.cache/huggingface/hub` (look for `models--mlx-community--whisper-large-v3-mlx`) |
| This repository | delete the folder |

The organisation-mode install is removed with `sudo scripts/uninstall.sh --company` ([docs/MIGRATION.md](MIGRATION.md) describes going back to a personal install).

## 11. Install problems

- `swiftc not found`: run `xcode-select --install`.
- `no usable Python 3.12 or newer`: install Python 3.13 (or 3.12) yourself or pass `MCAP_PYTHON`. Python older than 3.12 is refused, because the pinned numpy and scipy do not install on it; 3.12 only gets a warning because the pins were verified on 3.13.
- `make test-python` says that numpy is not importable: the tests need an interpreter with numpy. After `make install ARGS=--python` the Makefile uses the app's own environment; on a Mac with only the Command Line Tools install Python 3.12 or 3.13 yourself, create a venv with `pipeline/requirements.client.txt`, and run `make test-python PY=/path/to/that/venv/bin/python`.
- `--require-signing` stops immediately: create the identity (section 8) or leave the option out.
- The first meeting is slow: the model was not pre-downloaded. Run `scripts/setup_python.sh --pre-download-model` once.
- Anything else: `make doctor`, and see Troubleshooting in the [README](../README.md#troubleshooting). When you report a problem, paste `mcap doctor --share` output, which removes your home folder and e-mail addresses, and never attach recordings, transcripts or notes.
