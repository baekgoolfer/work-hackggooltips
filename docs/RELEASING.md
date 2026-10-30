# Releasing

This page is for maintainers. It explains what a release contains, what the GitHub Actions workflows do, how to cut a release, and which parts nobody has verified yet.

The release automation needs **no secret**. The only credential is the `GITHUB_TOKEN` that GitHub gives every workflow run, and only one job gets write access.

## What a release contains

| File | What it is |
|---|---|
| `meeting-capture-<version>-source.tar.gz` | `git archive` of the tagged commit. **The recommended way to install**: unpack it (or `git clone` and check out the tag) and follow the README. |
| `CATE-<version>-macos-arm64-adhoc.zip` (`<short name>-<version>-...` for a build with another `MCAP_APP_SHORT_NAME`) | `CATE.app` signed **ad-hoc** (`MC_CODESIGN_IDENTITY=-`), **not notarized**, next to `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES.md` (the ones that exist) and a `README-FIRST.txt` with the Gatekeeper steps. |
| `SHA256SUMS` | SHA-256 of the two files above. |

The release page body is `RELEASE_NOTES.md`, written by the script: the section of `CHANGELOG.md` for the version (a heading that contains `[<version>]` or `## <version>`), then what the files are and the Gatekeeper and quarantine steps.

Policy, on purpose:

- **No third-party binary is distributed.** The zip holds only the Swift app. No Python package, virtual environment, speech or VAD model and no font is bundled, so no third-party licence duty beyond `THIRD_PARTY_NOTICES.md` arises. If you ever ship a virtual environment or a `.pkg` with one, that changes: rebuild the notices for exactly what is inside.
- **No notarization, no Developer ID.** Both need an Apple Developer Program account that the project does not have. The release notes say so. A maintainer with an account can sign and notarize by hand; nothing in this repository runs `notarytool` (`scripts/build_pkg.sh` prints the commands for the organisation-mode package only). Do not store certificates or Apple credentials in GitHub secrets without a separate review.
- **The app zip is a convenience, not an install.** The app runs `pipeline/` from a source checkout (`PROJECT_DIR`) and needs the Python environment and model from `scripts/setup_python.sh`, so the zip alone cannot process a recording. The notes say that.
- **Releases are created as drafts.** A maintainer reads the notes and the assets and presses Publish. To publish automatically, remove `--draft` in `.github/workflows/release.yml`.

## The workflows

| File | Runs on | Does | Token |
|---|---|---|---|
| `.github/workflows/ci.yml` | push to any branch, pull requests, manual | `lint`: `bash -n` and shellcheck on the scripts and `scripts/release.sh --scan-only`. `swift`: `make build` (ad-hoc) and `make test-swift` (`selftest-detector`, `selftest-session`, `selftest-policy` and `selftest-capture --synthetic`), on `macos-26` and `macos-15`. `python`: unit tests in a venv made from `pipeline/requirements.client.txt` and one made from `pipeline/requirements.lock.txt` (`pip install --no-deps`, like `scripts/setup_python.sh`; no model is downloaded and `HF_HUB_OFFLINE=1`). `scripts`: `make test-scripts`. | read only |
| `.github/workflows/release.yml` | tag `v*`, manual | `build` runs `scripts/release.sh --tag <tag>` and uploads `dist/` as a workflow artifact. `publish` (tags only) checks the checksums and runs `gh release create --draft --verify-tag` with the three assets and the notes. A tag with a `-` in it (`v0.3.0-rc1`) becomes a pre-release. | `build`: read only. `publish`: `contents: write` |
| `.github/dependabot.yml` | weekly | Update pull requests for the pinned actions and for `pipeline/requirements*.txt`, grouped, after a 7 day cooldown. | n/a |

Every third-party action is pinned to a full commit SHA with the release in a comment (`actions/checkout`, `actions/setup-python`, `actions/upload-artifact`, `actions/download-artifact`). The release is created with the `gh` command that GitHub's runners already have, so no release action is needed.

CI proves that the app builds, the device-free tests pass and nothing key-shaped is in the tree. It does **not** prove live recording, the macOS permission prompts or Zoom and Teams detection: those need a real Mac and a real call (`docs/LIVE_TEST.md`).

`workflow_dispatch` on `release.yml` (Actions, Release, Run workflow) builds everything without a tag and keeps the files as a workflow artifact for 14 days. Use it to test the pipeline before the first real tag. It publishes nothing.

## Before the first public push

1. Commit the sanitized tree into a **fresh** repository. Never push the history of the private repository.
2. Decide the bundle identifier and the names. The tree builds with the neutral defaults `org.meetingcapture.app`, `Catch Everything` and `CATE`. If builds are shipped under your own name, set `MCAP_BUNDLE_ID` to your reverse-DNS id for every release build: as an environment variable for a local `scripts/release.sh`, and as the repository variable `MCAP_BUNDLE_ID` (Settings, Secrets and variables, Actions, Variables) for `release.yml`, which hands it to `scripts/release.sh` and so to `scripts/build_app.sh` (`CONTRIBUTING.md`, "Forks that distribute builds"). Without the variable the workflow builds, signs and verifies the zip under the neutral default, and nothing fails. macOS ties permissions to that identifier, so changing it later makes every user grant them again. Put the id and the two names in the private denylist of step 5 if they must never appear in a build you did not mean to make with them. The two names are inputs the same way: `MCAP_APP_NAME`, the human name (default `Catch Everything`: the title of the release page and the display name in the app) and `MCAP_APP_SHORT_NAME`, the file-safe short name (default `CATE`: the app folder and the name of the zip), as environment variables for a local `scripts/release.sh` and as the repository variables `vars.MCAP_APP_NAME` and `vars.MCAP_APP_SHORT_NAME` for `release.yml`, which hands them to `scripts/release.sh` (an unset variable is empty, which means the default; a value that breaks the rules of `docs/CONFIGURATION.md`, "Names and identifier of the app", stops the build before anything is built). Keep all three values for every release: a different short name is another app file next to the old one for everybody who updates.
3. Create the GitHub repository as **private** first and push. Wait for CI. Read Settings, Code security: any secret-scanning or push-protection alert must be understood before the repository becomes public.
4. Settings to switch on: Actions, General, Workflow permissions = *Read repository contents*; Code security: secret scanning, push protection, Dependabot alerts and private vulnerability reporting (`SECURITY.md` points there); a branch ruleset for the default branch that requires a pull request and the CI checks (`Lint and publish-safety scan`, `Swift build and self tests (macos-26)`, `Python tests (client venv)`, `Python tests (full venv)`, `Script tests`; add `Swift build and self tests (macos-15)` once it is green).
5. Run the scan with your own private patterns: put your name, e-mail address and company terms, one extended regular expression per line, in a file **outside** the repository and run `MCAP_SCAN_DENYLIST=/path/to/patterns.txt scripts/release.sh --scan-only`. The public script cannot contain those strings, which is the point.
6. Put the address of the repository into the install steps. They say `git clone <repository-url> meeting-capture` in `README.md`, `README.ko.md`, `CONTRIBUTING.md` and `docs/INSTALL.md`, because the address does not exist before the repository does:

   ```
   sed -i '' 's#<repository-url>#https://github.com/<handle>/meeting-capture.git#' README.md README.ko.md CONTRIBUTING.md docs/INSTALL.md
   ```

   `scripts/release.sh --tag` stops while that text is still in the tree.
7. Run `scripts/release.sh` once on an Apple silicon Mac (below) and try the zip as a user would: download it with a browser, not `curl`, on a Mac that has never seen it.

## Cutting a release

1. Put the changes under a new `## [X.Y.Z]` heading in `CHANGELOG.md` and give it its date, for example `## [0.2.0] - 2026-10-17`. The first release already carries that heading; change the date if you tag on another day.
2. Make the version equal everywhere: `__version__` in `pipeline/mcap/__init__.py` and, if the file exists, `VERSION`. `scripts/release.sh` refuses to run when they differ or when the requested version is not the tree's version.
3. Commit, push, and wait until CI is green on that commit.
4. Check what would be built: `scripts/release.sh --dry-run`.
5. Optional: build the assets locally with `scripts/release.sh` and look at `build/release/`.
6. Tag the commit that CI checked and push the tag:

   ```
   git tag -a vX.Y.Z -m "Catch Everything X.Y.Z"
   git push origin vX.Y.Z
   ```

7. Wait for the Release workflow. It creates a **draft** release. Read the notes, download the three files, run `shasum -a 256 -c SHA256SUMS`, and press Publish.

If the workflow fails after the tag was pushed: fix the cause, delete the tag locally and on the remote, and tag the fixed commit again. Never move a published tag.

## `scripts/release.sh`

```
scripts/release.sh [--version X.Y.Z] [--tag vX.Y.Z] [--out DIR] [--dry-run] [--scan-only] [--skip-app] [--skip-source]
```

It publishes nothing and touches no keychain. The workflow runs this same script, so a local run builds what CI would. Output goes to `build/release/` (ignored by git) unless `--out` says otherwise; only the files listed above are replaced there.

What it checks, in order. Any failure stops it with a message.

1. **The scan** of every file git would publish (tracked, plus untracked files that are not ignored): private key blocks, Anthropic, OpenAI-style, GitHub, AWS, Slack, Google and Hugging Face key shapes, absolute home directories of real people (placeholders such as `alice`, `user`, `someone` are fine), agent scratch paths, and Google Drive folders that name a concrete mailbox. It prints `file:line` and the kind and **never the matching text**, so a log never repeats a secret. If a hit is a deliberate test fixture, add a narrow allow rule at the top of the script with the reason; three test files that hold fake PEM headers are allowed that way today. Files with a NUL byte (such as the icon) are skipped.
2. **Version**: `VERSION` (when present) equals `__version__`, and the requested version or tag equals them.
3. **Tag** (`--tag` only): the tag is `vX.Y.Z` or `vX.Y.Z-pre`, exists in the clone and points at `HEAD`, `LICENSE` exists, and the placeholder of the first release is gone (the clone address in the install steps of `README.md`, `README.ko.md`, `CONTRIBUTING.md` and `docs/INSTALL.md`; an undated `CHANGELOG.md` heading also stops it).
4. **The app zip** (Apple silicon, native arm64 shell): `scripts/build_app.sh` with `MC_CODESIGN_IDENTITY=-` into a temporary directory (the app version is the numeric part of the version); `ditto` into a folder with the licence files and `README-FIRST.txt`; zip; then the zip is **unpacked and checked**: `codesign --verify --strict`, `Signature=adhoc`, the bundle identifier of `build_app.sh`, the version in `Info.plist`, no `__MACOSX` entries. Elsewhere the zip is skipped with a warning, except for a `--tag` run, which stops.
5. **The source tarball**: `git archive HEAD`. It needs a clone with a commit. Uncommitted changes are not in it (the script warns).
6. `SHA256SUMS` is written and checked with `shasum -a 256 -c`; `RELEASE_NOTES.md` is written.

`MCAP_RELEASE_SKIP_SCAN=1` skips the scan. It exists to test the script itself on a tree that is known to be unclean. CI never sets it, and nobody should for a release.

The zip is not reproducible (zip timestamps), the tarball is for a given commit. Compare checksums only against the `SHA256SUMS` of the same release.

## What users see: Gatekeeper and quarantine

- A build you compile yourself is **not quarantined**, so macOS does not check it for notarization. `git clone` and `curl` downloads are not quarantined either.
- A **browser download** of the zip is quarantined. macOS then refuses an app that is not notarized. The release notes and `README-FIRST.txt` tell users to compare the SHA-256 first and then: on macOS 15 or newer, try to open the app once and use System Settings, Privacy & Security, Open Anyway; on macOS 14, Control-click, Open; or remove the flag with `xattr -dr com.apple.quarantine CATE.app`.
- An ad-hoc signature is tied to the code hash, so macOS asks again for Microphone, System Audio Recording and Notifications after every new build. A fixed local signing identity (`scripts/make_signing_identity.sh`) avoids that for people who build themselves.

## Updating pins

**GitHub Actions.** Dependabot opens one grouped pull request a week. To pin by hand, or to check a pull request, resolve the release tag and confirm the commit exists in the action's repository:

```
gh api repos/actions/checkout/git/ref/tags/v7.0.1 --jq .object
gh api repos/actions/checkout/commits/<sha> --jq .sha
```

The first call must print type `commit` and the SHA; if it says `tag` (an annotated tag), resolve that tag object once more. The second must print the same SHA. Then write the SHA with the release in a comment: `uses: actions/checkout@<sha> # v7.0.1`. Read the release notes for breaking changes first. Prefer a release that is at least a week old.

**Python.** `pipeline/requirements.lock.txt` is installed with `pip install --no-deps`, so a bump must keep the set consistent: `mlx` and `mlx-metal` move together, `numpy` and `truststore` in `pipeline/requirements.client.txt` must stay equal to the lock (`scripts/test_scripts.sh` checks that), and `pipeline/requirements-server.txt` belongs to the Linux server (Python 3.11 or 3.12) that CI does not test. CI installs the lock and the client file on every pull request, which catches a missing wheel but not a behaviour change in a package: read what changed.

## Not verified

Nobody has run these workflows on GitHub yet, and the following were never tested. Treat the first runs as part of the work.

- That `ci.yml` and `release.yml` run green. The YAML parses, every `run:` block passes `bash -n`, and each step was checked against the Makefile and the scripts, but there is no GitHub runner here. Likely first-run surprises: the `macos-15` Swift leg if the sources use an API that only the newer SDK has, a Python test that needs a GPU or a real audio device on the runner, a test in `scripts/test_scripts.sh` that depends on the developer's machine.
- shellcheck: the step does not block (`continue-on-error`), because the scripts have never been run through it. Fix the findings and remove that line.
- That `actions/checkout` leaves the pushed tag in the clone (the tag check in `scripts/release.sh` relies on it) and that `gh release create --verify-tag --draft` accepts exactly these flags with the runner's `gh` version.
- The action SHAs were resolved through GitHub's public API pages and each was confirmed twice (tag to commit, commit back to the same SHA). Re-check them once with the `gh api` calls above before the first tag.
- The Gatekeeper steps in the notes describe standard macOS behaviour for a quarantined, not notarized app. They were not tried on a clean Mac with this zip, and macOS wording changes between versions.
- The scan was only run on macOS (BSD `grep`). The `lint` job on Ubuntu is its first run with GNU `grep`; the options used (`-s -H -I -n -o -E -e -f`, `xargs -0`) exist in both.
- Dependabot: that it picks up `pipeline/requirements.lock.txt` and `requirements-*.txt` (the file-name rule was read in Dependabot's source) and that the `cooldown` and `groups` keys are accepted by your GitHub version.
- Python 3.12: every pin's `Requires-Python` allows it and `scripts/setup_python.sh` accepts it, but no environment was built on 3.12; CI and the lock use 3.13.
- Artifact attestations (build provenance) are not set up. Adding them needs `id-token: write` and `attestations: write` on the build job and one more pinned action.
