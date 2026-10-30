# Catch Everything (CATE) - build, test, install helpers.   `make help` lists the targets.
# Works with the GNU Make 3.81 that ships with macOS. No Xcode needed (swiftc from the Command Line Tools).

.DEFAULT_GOAL := help
SHELL := /bin/bash

SUPPORT_DIR ?= $(HOME)/Library/Application Support/MeetingCapture
BUILD_DIR   ?= build
# The file-safe short name of the app (MCAP_APP_SHORT_NAME, default CATE) names the app folder and its program. The default and the rules live in ONE
# place, scripts/bundle_id.sh; a value it refuses stops make with its reason, before anything is built. The relative path is the one every recipe uses: a
# checkout path with a quote in it must not break the shell line. GNU Make 3.81 does not hand a variable given on the command line to $(shell), so the
# value would be ignored here while the recipes see it: it is refused.
ifeq ($(origin MCAP_APP_SHORT_NAME),command line)
$(error MCAP_APP_SHORT_NAME is a build input of the environment, not a make argument (make would name the app one thing and build another): run  MCAP_APP_SHORT_NAME=<name> make ...)
endif
APP_SHORT_NAME := $(shell /bin/bash -c '. scripts/bundle_id.sh; mcap_resolve_app_short_name' 2>/dev/null)
ifeq ($(APP_SHORT_NAME),)
$(error $(shell /bin/bash -c '. scripts/bundle_id.sh; mcap_resolve_app_short_name' 2>&1 >/dev/null))
endif
APP         := $(BUILD_DIR)/$(APP_SHORT_NAME).app
APP_BIN     := $(APP)/Contents/MacOS/$(APP_SHORT_NAME)
VENV_PY     := $(SUPPORT_DIR)/venv/bin/python

# Python used by `make test-python`: the production venv when it exists, else python3 (which needs numpy to be importable;
# `make test-python` checks that first). Override: make test PY=/path/to/python
PY ?= $(shell if [ -x "$(VENV_PY)" ]; then printf '%s' "$(VENV_PY)"; else printf python3; fi)

# Extra arguments for the scripts, e.g.  make install ARGS="--python --with-silero"   make uninstall ARGS=--purge
ARGS ?=
# Extra arguments for scripts/build_app.sh through `make build`, e.g.  make build BUILD_ARGS=--require-identity
BUILD_ARGS ?=

SWIFT_SOURCES := $(wildcard app/Sources/*.swift)

.PHONY: help build test test-swift test-python test-scripts install uninstall doctor set-api-key setup-python signing-identity confirm-live-tested clean lint bench-kit pkg policy hash-lock fetch-runtime dmg

help: ## show this list
	@echo "Catch Everything (CATE)"
	@echo
	@awk -F':.*## ' '/^[a-zA-Z_-]+:.*## / { printf "  make %-22s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Variables: PY=<python for tests> ARGS=<flags for the scripts> BUILD_DIR=<build dir, default build> BUILD_ARGS=<flags for build_app.sh> SUPPORT_DIR"
	@echo "Examples:  make test PY=/path/to/venv/bin/python     make install ARGS=\"--python --with-silero\"     make install ARGS=--dry-run"
	@echo "Note:      'make build' is incremental and does not re-sign when only the signing identity changed: use  make clean build   (a changed MCAP_BUNDLE_ID, MCAP_APP_NAME or MCAP_APP_SHORT_NAME does rebuild)"
	@echo "App id:    MCAP_BUNDLE_ID=<your reverse-DNS id> is a build input of build / install / dmg / pkg (default org.meetingcapture.app); use the same one every time (docs/CONFIGURATION.md)"
	@echo "App names: MCAP_APP_NAME=<human name> (default Catch Everything) and MCAP_APP_SHORT_NAME=<file name of the app, letters and digits> (default CATE) are build inputs of the same targets; use the same ones every time, and give them in the environment (MCAP_APP_SHORT_NAME=<name> make ...), not as make arguments"
	@echo "API key:   CLAUDE_AUTH=api needs the key once:  make set-api-key   then  python -m mcap api-key check  (docs: README, config.env)"
	@echo "Order:     make signing-identity -> make install ARGS=\"--require-signing --python --with-silero --pre-download-model\" -> setup / live tests (docs/LIVE_TEST.md) -> make confirm-live-tested -> scripts/make_launchagent.sh --load"
	@echo "Installer: fill scripts/python-runtime.lock once -> make fetch-runtime ARGS=\"--out-dir build/runtime\" -> make dmg (ARGS=--dry-run first) -> test on a second Mac -> share the .dmg (docs/DISTRIBUTE.md; nothing here uploads or notarizes)"
	@echo "Company:   make hash-lock -> venv (scripts/setup_python.sh --client-only ...) -> release manifest + offline signature -> make pkg ARGS=\"--release-dir ... --release-pubkey ...\" (docs/DEPLOY.md; nothing here installs, signs or notarizes)"

build: $(APP_BIN) ## build and sign build/<short name>.app, CATE.app by default (swiftc only; fixed identity if you made one, else ad-hoc)

# MCAP_BUNDLE_ID, MCAP_APP_NAME and MCAP_APP_SHORT_NAME are build inputs (defaults in scripts/bundle_id.sh): the stamp holds the three values and changes only
# when one does, so `make build` rebuilds for a new id or name (the sources did not change) and does not rebuild otherwise. The values go through the
# environment, never into the command line.
BUNDLE_ID_STAMP := $(BUILD_DIR)/.bundle-id

.PHONY: bundle-id-force
$(BUNDLE_ID_STAMP): bundle-id-force
	@mkdir -p "$(BUILD_DIR)"; v="$$(printf '%s\n%s\n%s\n' "$${MCAP_BUNDLE_ID:-}" "$${MCAP_APP_NAME:-}" "$${MCAP_APP_SHORT_NAME:-}")"; printf '%s\n' "$$v" | cmp -s - "$@" || printf '%s\n' "$$v" > "$@"

$(APP_BIN): $(SWIFT_SOURCES) app/Info.plist.template scripts/build_app.sh scripts/bundle_id.sh $(BUNDLE_ID_STAMP)
	MCAP_BUILD_DIR="$(BUILD_DIR)" scripts/build_app.sh $(BUILD_ARGS) >/dev/null

test: test-scripts test-swift test-python ## all device-free tests (script tests with stubs, Swift self tests, Python unittest)

# Device-free self tests: no microphone, no system audio, no permission prompt. Logs and temp files go to a temp dir,
# never into ~/Library/Logs/MeetingCapture or the real Application Support folder.
test-swift: build ## Swift self tests: selftest-detector, selftest-session, selftest-policy, selftest-capture --synthetic
	@set -e; \
	T="$$(mktemp -d "$${TMPDIR:-/tmp}/mcap-test.XXXXXX")"; trap 'rm -rf "$$T"' EXIT; \
	export TMPDIR="$$T" MCAP_LOG_DIR="$$T/logs" MCAP_CONFIG="$$T/config.env"; \
	mkdir -p "$$T/logs"; : > "$$T/config.env"; \
	echo "== selftest-detector";  "$(APP_BIN)" selftest-detector; \
	echo "== selftest-session";   "$(APP_BIN)" selftest-session; \
	echo "== selftest-policy";    "$(APP_BIN)" selftest-policy; \
	echo "== selftest-capture --synthetic"; "$(APP_BIN)" selftest-capture --synthetic --seconds 5 --out "$$T/capture"; \
	echo "swift self tests: all passed"

test-python: ## Python unittest (pipeline/tests); PY=... selects the interpreter (needs numpy)
	@"$(PY)" -c 'import numpy' >/dev/null 2>&1 || { \
	    echo "numpy is not importable with PY=$(PY), so the tests would fail with import errors."; \
	    echo "Create the production venv first (make setup-python) or pass an interpreter that has numpy: make test-python PY=/path/to/python"; \
	    exit 1; }
	@echo "== python unittest with $(PY)"
	PYTHONPATH="$(CURDIR)/pipeline" PYTHONDONTWRITEBYTECODE=1 "$(PY)" -m unittest discover -s pipeline/tests -v

test-scripts: ## tests of the shell scripts (install, uninstall, signing, bench kit, company pkg and ops scripts) with stubbed launchctl/security/codesign/pkgbuild, temp HOME
	scripts/test_scripts.sh

install: ## show the recording legal notice (type yes; --accept-legal-notice without a terminal), build + install the app, seed config; LaunchAgent only after confirm-live-tested (ARGS="--python --dry-run --require-signing" ...)
	scripts/install.sh $(ARGS)

uninstall: ## remove app + LaunchAgent, keep your data (ARGS=--purge to delete data too)
	scripts/uninstall.sh $(ARGS)

doctor: ## run `python -m mcap doctor` with the production venv (config, model cache, Claude login, archive dir)
	@if [ ! -x "$(VENV_PY)" ]; then echo "no venv at $(VENV_PY): run  make setup-python  first"; exit 1; fi
	cd pipeline && "$(VENV_PY)" -m mcap doctor

set-api-key: ## YOU run this once in Terminal (CLAUDE_AUTH=api): store the Anthropic API key in the macOS Keychain; the macOS security tool asks for it, nothing else sees it
	@if [ ! -x "$(VENV_PY)" ]; then echo "no venv at $(VENV_PY): run  make setup-python  first"; exit 1; fi
	cd pipeline && "$(VENV_PY)" -m mcap api-key set

setup-python: ## create the Python venv from the lock file (ARGS="--with-silero --pre-download-model --dry-run" ...; --client-only for the company client venv)
	scripts/setup_python.sh $(ARGS)

pkg: ## build the COMPANY installer package, unsigned unless ARGS names identities (ARGS="--dry-run" first; --release-dir DIR --release-pubkey FILE; docs/DEPLOY.md)
	scripts/build_pkg.sh $(ARGS)

policy: ## write the baseline organisation policy.json, or open one lane with an approval (ARGS="--revision 2 --allow drive=TICKET-1 --out policy.json"; docs/POLICY.md)
	scripts/make_policy.sh $(ARGS)

hash-lock: ## PLAN of the hash-pinned requirements for the company venv (nothing is fetched; ARGS=--apply asks pypi.org, the administrator runs that on the build host)
	scripts/make_hash_lock.sh $(ARGS)

fetch-runtime: ## download the Python runtime for the app installer into the folder named by ARGS="--out-dir build/runtime" (needs URL and SHA256 in scripts/python-runtime.lock; only the sha256 you pinned is accepted; ARGS=--dry-run to look first)
	scripts/fetch_python_runtime.sh $(ARGS)

dmg: ## build build/<short name>-<version>.dmg (CATE-<version>.dmg by default): the app with its pipeline, scripts and Python runtime inside, signed with your fixed identity (ARGS="--dry-run" first; docs/DISTRIBUTE.md)
	scripts/build_dmg.sh $(ARGS)

signing-identity: ## YOU run this once: create the fixed self-signed signing identity in your login keychain (ARGS=--dry-run to look first)
	scripts/make_signing_identity.sh $(ARGS)

confirm-live-tested: ## YOU run this after `setup` (no [FAIL]) and `selftest-capture --live` (PASS): unlocks writing/loading the LaunchAgent; shows the legal notice, asks you to type yes and 'confirmed'
	scripts/make_launchagent.sh --confirm-live-tested

clean: ## remove build output (app, bench kit) and Python bytecode caches
	MCAP_BUILD_DIR="$(BUILD_DIR)" scripts/build_app.sh --clean-only
	rm -rf "$(BUILD_DIR)/bench-kit-stage" "$(BUILD_DIR)/bench-kit.tar.gz" "$(BUILD_DIR)/dmg-stage"
	find pipeline scripts -name __pycache__ -type d -prune -exec rm -rf {} +

LINT_FILES := $(wildcard scripts/*.sh) $(wildcard scripts/bench_kit/*.sh) $(wildcard scripts/mdm/*.sh) $(wildcard scripts/asr_server/*.sh) scripts/pkg/preinstall scripts/pkg/postinstall

lint: ## bash -n and shellcheck (if installed) on all scripts
	@set -e; for f in $(LINT_FILES); do bash -n "$$f" && echo "bash -n ok: $$f"; done
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -x $(LINT_FILES) && echo "shellcheck ok"; else echo "shellcheck not installed: skipped"; fi

# Everything needed to run scripts/bench_asr.py on another Apple Silicon Mac, see docs/BENCH_KIT.md. The kit is staged in a
# directory first because it gets a marker file, BENCH_KIT, that exists ONLY in the kit: scripts/bench_kit/setup_bench_env.sh
# refuses to run without it, so it cannot be started by accident from this repository.
BENCH_KIT_FILES := pipeline/mcap pipeline/requirements.lock.txt pipeline/requirements-silero.txt pipeline/requirements-qwen-bench.txt \
                   scripts/bench_asr.py scripts/setup_python.sh scripts/bench_kit config/vocabulary.txt docs/BENCH_KIT.md
BENCH_STAGE := $(BUILD_DIR)/bench-kit-stage

bench-kit: ## pack build/bench-kit.tar.gz (marker file inside) for running the ASR benchmark on another Mac (docs/BENCH_KIT.md)
	@for f in $(BENCH_KIT_FILES); do [ -e "$$f" ] || { echo "missing $$f (needed for the bench kit)"; exit 1; }; done
	@rm -rf "$(BENCH_STAGE)" && mkdir -p "$(BENCH_STAGE)"
	@set -o pipefail; COPYFILE_DISABLE=1 tar -cf - --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' $(BENCH_KIT_FILES) | tar -xf - -C "$(BENCH_STAGE)"
	@printf 'meeting-capture bench kit, written by make bench-kit\n' > "$(BENCH_STAGE)/BENCH_KIT"
	COPYFILE_DISABLE=1 tar -czf "$(BUILD_DIR)/bench-kit.tar.gz" -C "$(BENCH_STAGE)" .
	@rm -rf "$(BENCH_STAGE)"
	@echo "wrote $(BUILD_DIR)/bench-kit.tar.gz ($$(du -h "$(BUILD_DIR)/bench-kit.tar.gz" | awk '{print $$1}')). Copy it to the other Mac by AirDrop/scp/USB, see docs/BENCH_KIT.md"
