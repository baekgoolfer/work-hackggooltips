# Contributing to Catch Everything

Thank you for helping. This project records other people's voices, so a few rules come before the build instructions.

## Rules that always apply

1. **Never commit or attach audio, transcripts, notes, logs or any real meeting data.** That includes issue attachments, pull-request screenshots and test fixtures. `.gitignore` blocks the usual audio and session files, but it cannot know what is in your paste. Test data must be synthetic.
2. **No secrets and no personal data.** No API keys or tokens (a fake key in a test must be obviously fake), no e-mail addresses, real names, company internals, or paths that contain your user name. Use `alice@example.com`, `Acme` and `/Users/someone`.
3. **Private by default.** A change that adds a network destination, sends more data than today, turns a lane on by default or weakens a safety gate needs an issue and a discussion first. See [docs/PRIVACY_AND_CONSENT.md](docs/PRIVACY_AND_CONSENT.md) for what leaves the Mac today.
4. **Security problems are not public issues.** Follow [SECURITY.md](SECURITY.md).
5. **Licence.** The project is under the Apache License 2.0 ([LICENSE](LICENSE)). By submitting a contribution you agree that it is licensed under the same terms (Apache 2.0, section 5); there is no CLA. Do not include code you cannot license that way. If you add a dependency, add it to [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) with its licence.
6. Be kind. Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Where things are

| Path | What |
|---|---|
| `app/Sources/*.swift` | the menu-bar app: detection, capture, session control, notifications, setup |
| `pipeline/mcap/` | the Python pipeline (`python -m mcap ...`): audio, speech recognition, cleanup, note, verification, publishing, CLI |
| `pipeline/tests/` | Python unit tests, golden files, fixtures |
| `config/` | `config.env.example` (the settings reference), prompts (`*_prompt.md`), `vocabulary.txt` seed, policy examples and fixtures |
| `scripts/` | install, uninstall, build, signing, release, packaging and their tests (`scripts/test_scripts.sh`) |
| `docs/`, `SPEC.md` | documentation; `SPEC.md` is the design contract (written in Korean; where it disagrees with the code and tests, the code wins) |

## Development setup

You need an Apple silicon Mac with macOS 14.4 or later (16 GB of RAM or more recommended) and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not used. You also need **Python 3.12 or 3.13**: the pinned numpy and scipy do not install on 3.11 or older, and the `python3` that comes with macOS or the Command Line Tools is not a substitute.

```bash
# the clone address is the HTTPS address shown on this repository's page
git clone <repository-url> meeting-capture
cd meeting-capture
python3.13 -m venv .venv                                       # Python 3.12 or 3.13 (3.11 and older do not work)
.venv/bin/pip install -r pipeline/requirements.client.txt     # numpy and truststore: enough for the Python tests
```

If you have already built the app's own environment (`make setup-python`, see [docs/INSTALL.md](docs/INSTALL.md)), the Makefile uses it automatically and you can skip the venv above. On a Mac with only the Command Line Tools there is no usable `python3`: install Python 3.12 or 3.13 yourself, make the venv as shown, and pass it with `make test-python PY=.venv/bin/python` (or `make test PY=.venv/bin/python`).

## Running the tests

| Command | What it runs |
|---|---|
| `make test` | the three test targets below (not `make lint`) |
| `make test-scripts` | the shell scripts (install, uninstall, signing, packaging, doc checks) against stubbed `launchctl`, `security`, `codesign` and `pkgbuild` and a temporary `HOME` |
| `make test-swift` | builds the app and runs its device-free self tests: `selftest-detector`, `selftest-session`, `selftest-policy` and `selftest-capture --synthetic` (CI runs the same target) |
| `make test-python PY=.venv/bin/python` | `python -m unittest discover -s pipeline/tests`; needs numpy |
| `make lint` | `bash -n` on all scripts, and `shellcheck` if it is installed |

One Python test module:

```bash
PYTHONPATH=pipeline PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m unittest discover -s pipeline/tests -p 'test_publish.py' -v
```

**These tests are device-free.** They need no microphone, no system-audio permission, no permission prompt and no network, and they never touch your real Keychain, `launchctl`, or `~/Library/Application Support/MeetingCapture`. Tests that need something you may not have (the Whisper model, onnxruntime, scipy, `afconvert`, generated speech clips) skip themselves. Keep it that way when you add tests: never call the real `security`, `launchctl`, `tccutil` or `open`, and write only to temporary directories.

CI (`.github/workflows/ci.yml`) runs the same device-free tests on GitHub Actions. They do not prove that live recording works. Real capture, permission prompts, and Zoom or Teams detection can only be checked on a real Mac with real calls: follow [docs/LIVE_TEST.md](docs/LIVE_TEST.md), and say in your pull request what you did and did not test.

Before you open a pull request, also run `scripts/release.sh --scan-only`. It is the publish-safety scan: it reports `file:line` and the kind (never the matching text) of secret-shaped strings, absolute home directories of real people and cloud-drive folders that name a mailbox.

## Code style

There is no formatter configuration. Match the code around your change; keep changes small and focused; comments explain why, not what.

- **Python:** `from __future__ import annotations`, type hints, standard library plus numpy. Do not add a runtime dependency without an issue: the 29 pins in `pipeline/requirements.lock.txt` are reviewed one by one (licence, size, supply chain). Keep side effects (processes, files outside the session, network, Keychain) behind the existing seams (the `deps` arguments, `egress.py` for outbound traffic) so tests can replace them.
- **Swift:** `swiftc` only, Apple system frameworks only, no Swift Package Manager. The Makefile compiles every `app/Sources/*.swift`. Put logic in pure functions that a `selftest-*` command can check without a device.
- **Shell:** must run under the bash 3.2 that macOS ships, with `set -euo pipefail`. A script that changes the system supports `--dry-run`, can be run twice, never overwrites a file the user edited, never asks for a password and never calls `sudo` itself.
- **Settings keys:** a new key goes into `pipeline/mcap/config.py` (and `app/Sources/Config.swift` if the app reads it), into `config/config.env.example` with an English and a Korean comment, and into the docs. `scripts/test_scripts.sh` checks that the keys the code parses are documented.
- **Prompts:** `config/note_prompt.md`, `cleanup_prompt.md` and `verify_prompt.md` are quoted by tests. Search `pipeline/tests` for the phrase you change before you edit.
- **Golden files:** `pipeline/tests/golden/` freezes the default output byte for byte. Regenerate it only on purpose (`python pipeline/tests/golden/make_golden.py --write --force`) and say so in the pull request.
- **Docs:** English first; Korean translations are welcome. Every command, flag and Makefile target a document names must exist: several docs are checked by `scripts/test_scripts.sh`, and that check also reads the word "make" followed by a lowercase word as a target name, so use "build" or "create" in prose.

## Pull requests

1. For anything larger than a fix, or anything touching privacy, permissions, detection thresholds or Claude billing behaviour, open an issue first.
2. One topic per pull request. Say why, not only what, and link the issue.
3. `make test` and `make lint` pass. Name any test that was skipped on your machine.
4. For changes to capture, permissions or detection state your macOS version and chip, and whether you tested live. Do not claim a live verification you did not do.
5. Update the docs, `config/config.env.example` and [CHANGELOG.md](CHANGELOG.md) (under Unreleased) when behaviour or settings change.
6. Fixtures are synthetic and contain no real people, companies, meetings or recordings.

Maintainers are volunteers; there is no response-time promise.

## Forks that distribute builds

The bundle identifier and the two names of the app are build inputs, not something written into the sources: set `MCAP_BUNDLE_ID` to your own reverse-DNS id, `MCAP_APP_NAME` to the human name and `MCAP_APP_SHORT_NAME` to the file-safe short name, for example `com.example.mcap-test`, `Example Recorder` and `ExampleRecorder`. Without them a build uses the neutral defaults `org.meetingcapture.app`, `Catch Everything` and `CATE`, which are shared by every copy built from this source and so name nobody. The id becomes the app's `CFBundleIdentifier`, the code-signing identifier, the label of the login agent and, as `<id>.pkg`, the identifier of the company package. The human name becomes `CFBundleDisplayName`, the name in the usage strings, every text of the app and the volume of the disk image; the short name becomes `CFBundleName`, the app folder `<short name>.app`, its program, the disk image `<short name>-<version>.dmg` and the release zip. The Swift code reads the names from the app's `Info.plist` at run time (a bare binary and the self tests use the defaults), and the scripts read them from the app they work on, then from the environment, then use the defaults; the Python pipeline reads them from the app that holds it, else from the environment (the app and the company `mcap` shim fill it with the app's own names), else uses the defaults. Nothing else needs editing:

```bash
export MCAP_BUNDLE_ID=com.example.mcap-test MCAP_APP_NAME="Example Recorder" MCAP_APP_SHORT_NAME=ExampleRecorder   # the same ones for every build you ship, so every script sees them
make install ARGS="--python --with-silero"      # or: make dmg, make pkg, scripts/release.sh
make test-scripts && make test-swift
```

An id is dot-separated labels of letters, digits and hyphens, at least two labels, no label starting or ending with a hyphen, at most 155 characters. A human name is ASCII letters, digits, spaces, hyphens and periods, starts with a letter or digit, has no trailing space and is 1 to 40 characters. A short name is ASCII letters and digits only, starts with a letter and is 1 to 32 characters. An empty value counts as unset, and anything that breaks a rule is refused before anything is built (`scripts/bundle_id.sh` holds the defaults and the rules; [docs/CONFIGURATION.md](docs/CONFIGURATION.md#names-and-identifier-of-the-app) has the table).

**Not renamed.** The data folder `~/Library/Application Support/MeetingCapture`, the organisation's `/Library/Application Support/MeetingCapture`, the log folder `~/Library/Logs/MeetingCapture`, the Keychain services (`MeetingCapture Anthropic API key`, `MeetingCapture ASR <engine>` and the like), the Python package `mcap`, the `MCAP_*` variables and the config keys are paths and identifiers, not the name of the product; a fork keeps them so that data and Keychain items that already exist stay found.

**Keep the id and the names the same on every build and every update.** To keep the names of a build that is already out, set `MCAP_APP_NAME` and `MCAP_APP_SHORT_NAME` to what the installed app already uses; an app file with another name next to the new one and the same bundle id is refused by the install guard of `scripts/build_app.sh --install`, because two apps with one id would share one login agent and one set of permissions. macOS ties the permissions (Microphone, System Audio Recording, Notifications) to the identifier and the signature. A stable id keeps them across updates; a different id is a different app to macOS and asks again (`tccutil reset All <old id>` clears the old entries if they get in the way). `scripts/build_app.sh --install` (so `make install`) refuses to replace an installed app that has another id, before it builds anything, and names the id to set; `MCAP_ALLOW_ID_CHANGE=1` switches on purpose, and the old id's login agent then has to be removed by hand (`launchctl bootout gui/$(id -u)/<old id>` and its plist in `~/Library/LaunchAgents`; the script prints both). A build you make only for your own Mac needs none of this, and neither does one that should stay the neutral default.

The speech server's daemon label, `org.meetingcapture.asr`, is not derived from the app's id (the server runs on another host): to use your own, rename `scripts/asr_server/org.meetingcapture.asr.plist.template` and change `LABEL` and the template path in `scripts/asr_server/install_server.sh`. `scripts/release.sh --scan-only` can keep a private id or private names out of a public release if you put them into the private denylist file (`docs/RELEASING.md`).

## Releases

Maintainers: [docs/RELEASING.md](docs/RELEASING.md) describes the workflows and how to cut a release. Release assets are built with `scripts/release.sh` (source tarball, `SHA256SUMS`, and on Apple silicon an ad-hoc signed, not notarized app zip). It publishes nothing by itself. The version in the `VERSION` file (when there is one) and `mcap.__version__` must agree; add the changes to [CHANGELOG.md](CHANGELOG.md) first.
