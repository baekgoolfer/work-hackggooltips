# The mcap-asr/1 server on Linux (faster-whisper backend)

Status: **experimental (organisation mode, SPEC 18).** Written for one organisation's installation, not reviewed by a lawyer, no support. Nothing here
changes an installed Catch Everything: no server exists until somebody installs one, and no client talks to one unless the organisation policy, a
consent and `ASR_ENGINE`/`ASR_FALLBACK` all say so (`docs/POLICY.md`). The wire contract is `docs/ASR_PROTOCOL.md`. This file is only about running the same server on a Linux host instead of an Apple silicon Mac.

**This was never run on a real GPU, never on a real Linux host, and never with a real `faster-whisper`.** The tests (`pipeline/tests/test_asr_faster_whisper.py`,
`scripts/asr_server/test_install_server_linux.sh`) put a fake `faster_whisper` module into `sys.modules` and stub `useradd`, `groupadd`, `systemctl`,
`chown` and python. They show that the backend calls faster-whisper the way this document says and that the installer does what it prints;
they do not show that CUDA, cuDNN, the pinned wheels, the sandbox of the unit or the speed work on your machine. Everything marked
[미검증] is from memory of the upstream documentation and has to be checked on the first real install. The first start is the test:
`python -m mcap.asr_faster_whisper check --load` (section 4).

한국어 요약: Apple silicon Mac mini 대신 NVIDIA GPU가 있는 Linux PC(또는 느리지만 CPU만 있는 Linux/Intel 호스트)에서 같은 `mcap-asr/1` 서버를 돌리는 방법이다.
서버 설정의 `backend`를 `faster-whisper`로 고르면 CTranslate2 기반 Whisper가 청크를 처리하고, 클라이언트는 아무것도 바꾸지 않는다(클라이언트는 이 백엔드를 import하지 않는다).
설치 스크립트는 기본이 계획 출력(dry run)이고, 서비스 사용자(root 아님), 엄격한 권한의 디렉터리, venv, systemd 유닛을 만든다. 루프백 또는 VPN 주소에만 바인드하고
루프백이 아니면 TLS가 필수다. 실제 GPU에서 검증한 적이 없다.

## 1. What this is

```
laptop (client, unchanged) --TLS, VPN--> [ mcap-asr/1 server, backend "faster-whisper" ] --> CTranslate2 --> GPU (or CPU)
```

* The server is `pipeline/mcap/asr_server.py` (work package W5b), unchanged. Its `backend` key names an engine; `faster-whisper` is
  `pipeline/mcap/asr_faster_whisper.py` (`FasterWhisperEngine`). The Apple silicon backend is `whisper` (MLX). Both give the client the same answer
  (`engine`, segments with `avg_logprob`, `no_speech_prob`, `compression_ratio`), so the post-filters, the prompt retry and the language
  logic of the client run unchanged. Health reports `engine: "faster-whisper"`, `kind: "server"`, `confidence: "logprob"`.
* The backend is registered as a **server backend** (`asr_engines.SERVER_BACKENDS`), not in the client registry. A client setting, a policy
  decision or the router can not name it, and importing the client (`mcap.asr`, `mcap.pipeline`, `mcap.cli`) never imports `faster_whisper`,
  `ctranslate2` or the backend module (a test pins both).
* Nothing leaves the host: the model is local, the service answers connections and never starts one, audio and text are never stored
  (the guarantees of the server do not depend on the backend). The unit additionally denies every network except loopback and the
  networks you list.
* Decoding is the SPEC 13.2 setting of the Mac path (temperature fallback 0 / 0.2 / 0.4 / 0.6, compression ratio 2.4, log-prob -1.0,
  no-speech 0.6, no conditioning on previous text, no word timestamps) plus beam 5. faster-whisper's own VAD is off (the client already cut
  the speech). The vocabulary goes to `initial_prompt`, counted against the 140-token budget with the model's own tokenizer; `hotwords`
  is not used. Language ID is the model's, restricted to the languages the client sends (default ko, en).
* Not measured: speed, and the accuracy of this backend on Korean-English meetings.
  Compare a sample of synthetic or your own recordings against the Mac path before you rely on it (design 8.2 rules apply to real audio).

## 2. Hardware

| | GPU server (the target) | CPU only |
|---|---|---|
| Machine | x86_64 PC or workstation with an NVIDIA GPU of the **16 GB class** (for example RTX 4060 Ti 16 GB, RTX 4070 Ti SUPER, RTX A4000, T4), 16 GB RAM or more, a few free cores | any x86_64 host with AVX2, 16 GB RAM |
| Model | `large-v3` (about 3 GB on disk) in `float16` | `int8`; `large-v3` is far slower than real time on a few cores. Smaller models are faster and worse |
| GPU memory | large-v3 float16 beam 5 is about 3 to 5 GB by the upstream figures [미검증]: 16 GB leaves room for one worker and the CUDA context | - |
| Disk | 10 GB free for the venv, the model cache and logs (20 GB if the CUDA libraries come from pip) | same |
| OS | a distribution with systemd 245 or newer (Ubuntu 22.04 or 24.04, Debian 12) | same, or an Intel Mac mini, see below |
| Python | **3.11 or 3.12** (the pinned wheels; 3.13 has none for numpy 1.26.4) | same |

The engine runs one decode at a time (the server has one engine worker and a fair queue). A 16 GB card does not make requests parallel; it
makes each one fast. Size the quotas (`max_queue`, `max_wait_s`, `per_token_*`) from a measurement on the real machine.

**Intel hosts (a Mac mini class machine, an old PC):** the same backend runs on the CPU with `device: cpu`, `compute_type: int8`, only slowly.
Two ways: run Linux on it and use this installer, or keep macOS and render the LaunchDaemon with `scripts/asr_server/install_server.sh --stage-dir`
(its `--apply` refuses a machine that is not Apple silicon), build a venv from `pipeline/requirements-server.txt` (ctranslate2 publishes CPU wheels
for macOS on Intel [미검증]) and set `"backend": "faster-whisper"` in its `asr-server.json`. Expect a large model to need several times the
audio duration, so the quotas must be lowered and the clients should keep `ASR_FALLBACK` on a local engine. The client app itself stays
Apple silicon only (design 0.1, contradiction 3). `distil-large-v3` is English-only: do not use it for Korean meetings.

## 3. Prerequisites the installer does not install

1. **NVIDIA driver** for CUDA 12 (driver 525 or newer on Linux [미검증]); `nvidia-smi` must list the card.
2. **CUDA 12 runtime libraries (cuBLAS 12) and cuDNN 9.** `ctranslate2` 4.5.0 (the pin) is built for CUDA 12 and cuDNN 9; CUDA 11 or cuDNN 8
   needs an older ctranslate2 (3.24.0 and 4.4.0 respectively, upstream notes) [미검증]. Install them from the distribution or NVIDIA's repository, or
   inside the venv with `nvidia-cublas-cu12` and `nvidia-cudnn-cu12==9.*` (uncomment them in `pipeline/requirements-server.txt`) and a
   systemd drop-in that puts their `lib` directories on `LD_LIBRARY_PATH`. These two packages are proprietary NVIDIA software under NVIDIA's own
   licence terms: installing them means you accept those terms, and they must never be copied into an image or archive that you publish:
   ```
   systemctl edit mcap-asr
   [Service]
   Environment=LD_LIBRARY_PATH=/opt/mcap-asr/venv/lib/python3.12/site-packages/nvidia/cublas/lib:/opt/mcap-asr/venv/lib/python3.12/site-packages/nvidia/cudnn/lib
   ```
3. **`/dev/nvidia-uvm` must exist when the service starts** (`nvidia-persistenced`, or `nvidia-modprobe -u -c=0` at boot). The unit has
   `NoNewPrivileges`, so the service can not load the module itself; without it CTranslate2 sees no GPU. The NVIDIA device files must be
   readable by the service user (`ls -l /dev/nvidia*`; the usual drivers make them world-accessible). If yours are not, add
   `SupplementaryGroups=video` (or the group they use) in the drop-in. The unit deliberately sets neither `PrivateDevices` nor `DevicePolicy`.
4. A root-owned copy of the project, for example `/opt/mcap-asr/app` (the installer refuses a project the service user could change, and one
   under `/home` or `/root`, which the sandbox hides).
5. A DNS name for the server, a certificate for it and the private CA that signed it (section 5), and a VPN or LAN (section 6).

## 4. Install

```
sudo install -d -m 755 /opt/mcap-asr && sudo cp -R <checkout> /opt/mcap-asr/app && sudo chown -R root:root /opt/mcap-asr/app

scripts/asr_server/install_server_linux.sh --project /opt/mcap-asr/app                # 1. the plan: read it, nothing is changed
sudo scripts/asr_server/install_server_linux.sh --project /opt/mcap-asr/app --apply   # 2. do it (the script never calls sudo itself)
```

Without options the script is a **plan**: it prints the service user, the directories, the venv and pip commands, the rendered
`asr-server.json`, the rendered unit and the next steps, and changes nothing. `--stage-dir DIR` writes the file tree under `DIR` (no root, no user, no venv)
for a rehearsal. `--apply` creates:

| What | Where | Mode, owner |
|---|---|---|
| service user and group `mcap-asr` | system account, no login, no shell, no password, not root | |
| config | `/etc/mcap-asr/asr-server.json` | 0644 root (the service can not change its own limits); never overwritten |
| tokens, enrollment codes, TLS files, service home with the model cache | `/var/lib/mcap-asr` (`home/` inside) | 0700 `mcap-asr`; `tls.key` 0600 |
| metadata log (content-free) | `/var/log/mcap-asr` | 0700 `mcap-asr` |
| venv with `pipeline/requirements-server.txt` | `/opt/mcap-asr/venv` | root; the service can not change what it imports |
| unit | `/etc/systemd/system/mcap-asr.service` (from `scripts/asr_server/mcap-asr.service.template`) | 0644 root |

Re-running is an upgrade: the venv gets the pins again, the unit is rewritten, the config and the data are kept. The script refuses a path that
is a symbolic link, a directory that is not empty and was not made by it, and a directory owned by somebody else, before it changes anything.
"Not made by it" is judged for the support directory and for the log directory alike: one that holds files but neither the marker
`.mcap-asr-install` nor `tokens.json` (support) / a `meta-*.jsonl` file (log) is refused, so a mistaken `--log-dir /var/log` is never
chmod 700 and chowned (an empty directory is fine).
Useful options: `--device auto|cuda|cpu`, `--compute-type float16|int8_float16|int8`, `--model large-v3`, `--listen`, `--tls-cert`, `--tls-key`,
`--allow-from`, `--wheelhouse DIR` (a host without internet access installs the pinned wheels from a directory only), `--start`.
The service is not enabled or started: do the following first, as the service user (the commands are printed with the real paths):

```
sudo -u mcap-asr env HOME=/var/lib/mcap-asr/home PYTHONPATH=/opt/mcap-asr/app/pipeline /opt/mcap-asr/venv/bin/python -m mcap.asr_faster_whisper check
... -m mcap.asr_faster_whisper fetch --yes        # about 3 GB from huggingface.co: after the pip install, the only step that uses the network; the service stays offline
... -m mcap.asr_faster_whisper check --load       # starts the model on the chosen device and decodes one second of silence
... -m mcap.asr_server --config /etc/mcap-asr/asr-server.json selfcheck      # prints build_sha256 for the policy
sudo systemctl enable --now mcap-asr.service
```

`check` reports the installed versions, the CUDA devices CTranslate2 sees, the device plan and whether the model files are complete (it
needs `model.bin`, `config.json`, `tokenizer.json` and a vocabulary file: without `tokenizer.json` faster-whisper would fetch a tokenizer from
the hub). `check --load` is the real test of the GPU stack: a cuDNN library that is missing shows only when the first chunk is decoded, so
`load()` decodes one second of silence. Then enrollment codes: `... -m mcap.asr_server --config /etc/mcap-asr/asr-server.json enroll-code issue --user NAME`.

### Configuration (`backend_options` of `asr-server.json`, strict: an unknown key refuses to start)

| Key | Values (default) | Meaning |
|---|---|---|
| `device` | `auto` (default), `cuda`, `cpu` | `auto`: the GPU if CTranslate2 sees one, else the CPU (WARNING in the journal). `auto` also falls back to the CPU, with a WARNING, if the GPU model fails to start or to decode. `cuda` **never** falls back: no GPU or a broken CUDA stack is an error at start. `cpu`: the CPU |
| `compute_type` | `float16` (default), `int8_float16`, `int8` | The two float16 types do not exist on the CPU and become `int8` (WARNING). On a GPU that lacks the requested type the chain float16, int8_float16, int8 is walked down |
| `beam_size` | 1 to 10 (5) | |
| `device_index` | 0 or more (0) | which GPU |
| `cpu_threads`, `num_workers` | 0 (library default), 1 | CTranslate2 settings; the server has one engine worker, so leave `num_workers` at 1 |
| `warmup` | true (default), false | decode one second of silence at start |

`model` (top level of the file; empty = `large-v3`): a short name (`tiny`, `base`, `small`, `medium`, `large-v2`, `large-v3`,
`distil-large-v3`; the turbo model has no short name: use its repo id), a Hugging Face repo id of a CTranslate2 model, or an absolute directory. An MLX model (`mlx-community/...`) is refused. A name or
repo id is what clients see in health and what a consent can name; a directory path is shown as it is, so prefer a name and let the cache hold the files.
The server never downloads (`allow_download` is not an option, `HF_HUB_OFFLINE=1` is set by the unit and by the server itself, and the engine honours
the variable even where a download would otherwise be allowed). The model is pinned by name only: **no revision is pinned** (the MLX model has one in
`REVISION_PINS`); pin one after you have checked the files you fetched.

## 5. TLS

A non-loopback address needs `tls_cert` and `tls_key`; the server refuses to start without them (the installer refuses earlier). Clients never connect to an
IP literal: the certificate carries the DNS name clients use (a SAN), and the client trusts only the private CA whose SHA-256 is in the policy
(`org_consents.ca_sha256`, `docs/POLICY.md`). With a private CA (keep `ca.key` offline; these commands were not run here):

```
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key && openssl req -x509 -new -key ca.key -sha256 -days 1825 -subj "/CN=ASR CA" -out ca.pem
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out tls.key && openssl req -new -key tls.key -subj "/CN=asr.example.internal" -out tls.csr
printf 'subjectAltName=DNS:asr.example.internal\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' > ext.cnf
openssl x509 -req -in tls.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 397 -sha256 -extfile ext.cnf -out tls.crt
sha256sum ca.pem            # the 64 hex characters for org_consents.ca_sha256
sudo scripts/asr_server/install_server_linux.sh --project /opt/mcap-asr/app --apply --listen 10.8.0.1:8443 --tls-cert tls.crt --tls-key tls.key --allow-from 10.8.0.0/24
```

The installer copies the two files to `/var/lib/mcap-asr/tls.crt` (0644) and `tls.key` (0600, `mcap-asr`), checks that they are PEM and not swapped, and refuses an
encrypted key (the service can not ask for a passphrase). It leaves existing TLS files alone: **a renewal is a copy by hand**, then `systemctl restart mcap-asr`.
Alternative: bind loopback (the default, plain HTTP) and put nginx or caddy on the same host; the terminator holds the certificate and forwards to
`127.0.0.1:8443`. Then the terminator is what listens on the VPN address, and its configuration is yours to harden.

## 6. VPN and firewall

The server must not be reachable from the internet. Three layers, and the installer prints the commands for the last two:

1. **Bind**: `--listen` accepts loopback, or one private address (10/8, 172.16/12, 192.168/16, 100.64/10 which Tailscale uses, fc00::/7, fe80::/10). It refuses `0.0.0.0`,
   `::`, a public address, a host name, and a port below 1024 (the service has no capabilities). A non-loopback bind needs TLS and `--allow-from`.
2. **The unit**: `IPAddressDeny=any` plus `IPAddressAllow=localhost` and each `--allow-from` network (each must lie inside a private range). The service can only
   be reached from those networks and can not open a connection anywhere else. A mistake here shows as clients timing out: check
   `systemctl cat mcap-asr` first.
3. **The host firewall**, default deny incoming, for example `ufw default deny incoming && ufw allow from 10.8.0.0/24 to any port 8443 proto tcp && ufw enable`.
   Never forward the port on a router and never open it on a public interface.

VPN: WireGuard (the bind address is the server's address in the tunnel) or Tailscale (the address in 100.64.0.0/10). The address must exist when the service starts: order the unit after
the VPN, `systemctl edit mcap-asr` with `[Unit]` `After=wg-quick@wg0.service` (and `Requires=` if you want the service to wait). Clients resolve the
certificate's DNS name to the tunnel address (internal DNS, or a hosts entry pushed by MDM).

Client side (unchanged, `docs/POLICY.md` and `docs/PRIVACY_LANES.md`): `ASR_ENGINE=remote`, `ASR_REMOTE_URL=https://asr.example.internal:8443`; the policy lists the host in `asr.allowed_hosts`
and an `org_consents` entry with `backend_kind: "server"`, the CA hash and the build hash from `selfcheck`.

## 7. Updates

* **Server code**: copy the new release to a new root-owned directory, run the installer with `--project <new>` (an upgrade) and `systemctl restart mcap-asr`.
  `selfcheck` prints a new `build_sha256`. Clients refuse a build that is not in the policy's `attest_build_sha256`: **add the new hash to the policy first**, then restart the server.
* **Python packages**: change the pins in `pipeline/requirements-server.txt`, run the installer again (`--wheelhouse` for an offline host), restart, run `check --load`. The three pins are
  versions that existed when the file was written, not run here; after the first good install run `pip freeze > requirements-server.lock.txt` and install from a hash-checked lock
  from then on. A new GPU generation can need a newer ctranslate2 together with newer CUDA libraries.
* **Model**: `fetch --yes --model <name>` as the service user, set `model` in `/etc/mcap-asr/asr-server.json`, restart, `check --load`. A changed model name is visible to clients in health.
* **Driver and CUDA**: the usual way this breaks is an unattended kernel or driver update. Hold the NVIDIA packages (`apt-mark hold`) and update them on purpose, then reboot and run
  `check --load` before the service is trusted again. After every reboot `/dev/nvidia-uvm` must exist (section 3).
* **The unit**: local changes go in a drop-in (`systemctl edit`); the installer rewrites the unit file, not the drop-ins.

## 8. Backups

There is no audio and no transcript to back up: the server stores none. Back up what is hard to recreate, with its modes (the server's `selfcheck` checks them again after a restore):

| Back up | Why | Care |
|---|---|---|
| `/etc/mcap-asr/asr-server.json` | the limits and the backend | |
| `/var/lib/mcap-asr/tokens.json` | the user rows and SHA-256 digests of tokens (never a token); without it every user enrolls again | 0600; encrypted backup |
| `/var/lib/mcap-asr/tls.key`, `tls.crt` | the server certificate | 0600; encrypted backup; the CA key stays offline |
| `/var/log/mcap-asr/meta-*.jsonl` | the content-free access log; its retention (`metadata_log_days`, default 400) is a legal decision (design 10.7); the daily quotas are rebuilt from it | 0700 |
| `mcap-asr.service` and any drop-in | | |

Do not back up the model cache (`home/`, 3 GB, fetched again), the venv (rebuilt from the pins) or `enroll-codes.json` (one-time, 10 minutes).
A restore is: install (section 4), stop the service, restore the files with the same owner and mode, `selfcheck`, start.

## 9. Monitoring

* `systemctl status mcap-asr` and `journalctl -u mcap-asr`: the server writes content-free lines only (a startup banner with the backend and the build prefix, one line a minute
  for counted refusals, WARNINGs of the backend: a CPU fallback, a compute type that was lowered). The service restarts after 30 s and stops retrying after 5 failures in 10 minutes
  (`StartLimitBurst`): `systemctl reset-failed mcap-asr` after fixing the cause.
* Liveness without a token: `curl --cacert ca.pem https://asr.example.internal:8443/v1/health` answers `{"proto":"mcap-asr/1","ok":true}` once the model is loaded.
  With a token and `?detail=1` it reports the engine, the model, `retention.mode`, the attest hashes and `queue.avg_service_s`.
* Alert on: the service not active; `ok` false; a rising `avg_service_s` or many `503 busy` / `429` lines in the metadata log (the log has `status` and `queue_ms` per request); free space in
  `/var/lib/mcap-asr` and `/var/log/mcap-asr`; the certificate's expiry (`openssl x509 -enddate -noout -in /var/lib/mcap-asr/tls.crt`); GPU health (`nvidia-smi --query-gpu=temperature.gpu,
  utilization.gpu,memory.used --format=csv`, throttling, a card that dropped off the bus, which the unit would then report as a CPU fallback on `auto`).
* `python -m mcap.asr_server --config /etc/mcap-asr/asr-server.json audit --daily` each morning (new source networks, audio hours that spike, machine changes per token) and
  `audit --home /var/lib/mcap-asr/home` each quarter (no audio file and no non-metadata log content in the service directories).
* A server that runs on the CPU although it should have a GPU is slow, not down: watch `avg_service_s`, and use `device: cuda` where a silent fallback is worse than an error.

## 10. When something is wrong

| What you see | Cause and fix |
|---|---|
| `faster-whisper cannot be imported: pip install -r pipeline/requirements-server.txt ...` | the venv of the unit has not got the packages (or a shared library of CTranslate2 or onnxruntime is missing: the text after `[` names it). Re-run the installer, then `check` |
| `device 'cuda' was requested but CTranslate2 sees no CUDA device` | driver, `/dev/nvidia-uvm`, device permissions, or CUDA 12 libraries not found (`LD_LIBRARY_PATH` drop-in). `nvidia-smi`, then `check` as the service user |
| `could not start on cuda ... Could not load library libcudnn_ops.so.9` | cuDNN 9 missing or not on the library path. With `device: auto` the server fell back to the CPU and said so |
| `CUDA failed with error out of memory` | another process holds the card (`nvidia-smi`), or use `compute_type: int8_float16` |
| `model ... is not available locally and downloads are disabled` | the model is not in the cache of the service user: run `fetch --yes` **as that user** with `HOME=/var/lib/mcap-asr/home`, without `HF_HUB_OFFLINE` |
| `is not a complete CTranslate2 Whisper model` | a directory without `model.bin`, `tokenizer.json` or a vocabulary file, or a converted model that lacks them |
| the service restarts every 30 s | `journalctl -u mcap-asr`: the first line after `startup refused:` names the failing self-check (a mode, a bind without TLS, a model) |
| clients time out | the unit's `IPAddressAllow` does not include their network, the firewall, the VPN, or the name in the certificate does not match the name they use |
| `503 busy` | the queue is longer than `max_wait_s`; the clients wait or fall back. Measure `avg_service_s`, then raise capacity or lower quotas |

## 11. What was and was not checked

Checked (fakes, stubs, no network): the backend's call into faster-whisper (language, `initial_prompt`, `vad_filter=False`, beam, thresholds, no hotwords), the mapping of segments and
log-prob fields, language ID, the 140-token prompt budget with a model tokenizer, the device and compute-type plan and the CPU fallback, the lazy-import error text, the offline
model rules, `release()`, a request through the real server core, that no client module imports the backend, the installer's plan, staged tree and `--apply` path
through stubbed system tools, its refusals (links, foreign owners, root, wildcard and public binds, missing TLS) and the unit's contents.

Not checked: a real GPU, CUDA 12, cuDNN 9, a real `faster_whisper` or `ctranslate2`, the pinned versions (never installed here), `systemd-analyze verify` or any systemd sandbox directive on a
real system, `IPAddressAllow` behaviour, real speed and the quotas that follow from it, Korean-English accuracy of this backend against the MLX path, pip behaviour on your index, the
`fetch` download, the repository names in `MODEL_REPOS`, driver and cuDNN version numbers in section 3, and Intel macOS wheels.
