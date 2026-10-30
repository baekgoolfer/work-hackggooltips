# mcap-asr/1: chunk-level ASR wire protocol

Status: **experimental (organisation mode, SPEC 18).** Written for one organisation's installation, not reviewed by a lawyer, no support. Nothing here
changes the behaviour of an installed Catch Everything: no server exists until somebody installs one, and no client talks to one unless the organisation
policy, a consent and `ASR_ENGINE`/`ASR_FALLBACK` all say so (`docs/POLICY.md`, `docs/PRIVACY_LANES.md`). This file is the wire contract the client (`pipeline/mcap/asr_remote.py`)
and the server (`pipeline/mcap/asr_server.py`) are built against independently: they share this document, not code.

한국어 요약: 노트북(클라이언트)이 VAD로 자른 발화 청크 하나(16 kHz mono int16 PCM, 약 28초 이하)를 HTTPS로 회사 ASR 서버에 보내고 JSON 전사를 받는다.
서버는 요청 본문을 메모리에서만 처리하고 오디오와 텍스트를 저장하지 않는다(120초 멱등 캐시 제외). 에코 제거, VAD, 청크 계획, 후처리는 전부 클라이언트에서 한다.
작업 단위(2트랙 업로드, TTL, 삭제 확인)는 `mcap-asr/2` 예약안이고 만들지 않았다.

One request carries ONE speech chunk (or one batch of short language-ID clips). The server holds no stored object (section 9).

## 1. Roles and what is (not) on the wire

| Piece | Where it runs | On the wire? |
|---|---|---|
| Echo cancellation (`aec`), speaker-leakage suppression (`suppress_echo`), VAD, chunk plan, aliases, post-filter | client, always | no: only their result goes out |
| Speech chunk: 16 kHz mono little-endian int16 PCM, at most about 28 s, taken after echo cancellation (the raw microphone when it was not applied) | client to server | yes (`POST /v1/chunk`) |
| Language-ID clip: at most 6 s each, at most 12 per request | client to server | yes (`POST /v1/lid`) |
| Vocabulary terms (partner and competitor names can be in them) | client to server | only when `ASR_SEND_VOCAB` is on and the consent text said so (`PUT /v1/vocab/{sha256}`) |
| Silence, meeting title, session id, platform, attendees, file names | never | no |

The audio can contain the voices of remote participants (the system-audio track): the consent text says so.

A server with a cloud backend (relay) forwards the chunk to one vendor host through its own egress guard. The client learns this from
`GET /v1/health` (`kind:"cloud"`, `vendor`) and a consent is bound to the `backend_kind` it was given for.

## 2. Transport

HTTPS only (TLS 1.2 or newer), HTTP/1.1, `Content-Length` required, no redirects (the client treats any 3xx as an error and never follows
it), no cookies, no request compression, one new connection per request. The server rejects `Transfer-Encoding`, two `Content-Length`
values, `Expect` and `Upgrade` (400). A server behind a TLS terminator binds loopback only and refuses a non-loopback plaintext bind. The
client allows exactly the consented host and port (a DNS name, never an IP literal). Server deadlines: request headers 10 s, body 30 s,
the whole request including queue wait, compute and response 120 s. The server also caps concurrent unauthenticated connections (16) and
idle time (10 s). Request bodies are limited to 2.5 MB and responses to 256 KB (the client enforces both).

## 3. Authentication

`Authorization: Bearer mcap1_<id8>_<secret32>` (id: 8 hex characters, secret: 32 url-safe characters). The server stores only
`sha256(secret)` per `id8`, with a user label, issue time, expiry (default 90 days), last-used time and issuer, in a 0600 file that it
re-reads when the mtime changes; the comparison is constant time. The token is opaque on the wire (a future broker can mint relay tokens
without a protocol change). Revocation = disabling the row; it is effective at the next request.

`GET /v1/health` without a token answers only `{"proto":"mcap-asr/1","ok":true}`. Every other endpoint except `POST /v1/enroll` requires
the token (`401 unauthorized`).

On the client the token lives in the macOS Keychain, service `MeetingCapture ASR remote`, account `<user>@<host>:<port>`, so it can only
be read for the host and port it was issued for. It is never written to a file, argv or the environment, and never logged.

## 4. Common request headers

```
X-MCAP-Proto:   mcap-asr/1
X-MCAP-Client:  mcap/0.2.0
X-MCAP-Run:     <16 hex random per pipeline run>      # log correlation only; never a session id, title or platform
X-MCAP-Idem:    <uuid4 per request>                   # retries reuse it
X-MCAP-Machine: <16 hex, sha256(machine id)[:16]>     # optional soft binding: the server logs changes, it never rejects on it
```

`X-MCAP-Proto` is mandatory on every request. Header names are case-insensitive (HTTP). A server ignores request headers it does not know.

## 5. Endpoints

### 5.1 GET /v1/health[?detail=1]

`detail=1` needs the token.

```json
{"proto":"mcap-asr/1","ok":true,"engine":"whisper","model":"mlx-community/whisper-large-v3-mlx","revision":"49e6aa28",
 "kind":"server","supports_lid":true,"confidence":"logprob",
 "limits":{"sample_rate":16000,"max_chunk_samples":496000,"max_lid_clips":12,"max_lid_clip_samples":96000,"max_wait_s":45,"concurrency_per_token":2},
 "retention":{"mode":"none","audio_disk":false,"text_disk":false,"memory_cache_s":120,"log_content":false},
 "attest":{"build_sha256":"<hex>","config_sha256":"<hex>","started":"2026-10-14T09:00:00+09:00","hf_offline":true,"core_dumps_disabled":true},
 "vendor":null,"token":{"expires_in_days":71},"queue":{"depth":2,"avg_service_s":4.1}}
```

Relay backend: `"kind":"cloud"`, `"vendor":{"name":"azure-speech","region":"koreacentral","claim_url":"https://learn.microsoft.com/...data-privacy-security","verified":false}`,
`"confidence":"opaque"`, `"supports_lid":false`.

The client refuses (`EnginePolicyDenied`) when:

- `proto` differs from `mcap-asr/1`;
- `retention.mode` is not `"none"`;
- `kind` differs from the `backend_kind` of the consent (or the organisation consent) it runs under;
- `attest.build_sha256` is not in the policy `attest_build_sha256` allow list (when the policy has one).

A changed `attest` otherwise only raises a warning and a status counter; it does not require re-consent (a server update must not send every
employee to a terminal). `retention` and `attest` are self-reported: they are not proof against a compromised server (section 9).

The client reads health before the first chunk of every run (within 5 s, so a black-holed host cannot burn minutes), in
`mcap asr-engines check` and in `mcap doctor`.

`max_chunk_samples` 496000 is 31 s at 16 kHz (the client plans chunks of about 28 s or less); `max_lid_clip_samples` 96000 is 6 s.
A limit is only ever used to SHORTEN the 28 s window: the client takes the shortest usable value of its own and the server's, and ignores a
server value that is missing, not a finite number, below 1 s or above 28 s (it never lengthens the window and never stops planning).
A health check or language-ID request that cannot reach the server is the same waiting condition as an unreachable chunk (the client raises
`AsrUnreachable`, which the pipeline reports as `asr_unreachable`, see `docs/PRIVACY_LANES.md`).

### 5.2 POST /v1/enroll (no token)

Body `{"code":"<one-time code>","machine":"<16 hex>"}` gives `200 {"token":"mcap1_...","expires":"<ISO>","user":"<label>"}`.

The code is single use, valid 10 minutes, stored hashed. Any wrong, used or expired code gets the same `401 enroll_invalid` (a uniform answer,
no hint which); repeated failures from one source get `429 enroll_throttled`. The pipeline (not the app) stores the returned token in the
Keychain; the enrollment code is not a secret once used and never appears in argv (`--code-stdin`).

### 5.3 POST /v1/token/renew (token)

`200 {"token":"mcap1_...","expires":"<ISO>"}`. The old token stays valid for 24 hours. The client calls it at run start when
`token.expires_in_days` is 14 or less and overwrites its Keychain item (same host-bound account).

### 5.4 PUT /v1/vocab/{sha256}

Body `{"terms":["Acme","AcmeScan-CXR", "..."]}` (UTF-8 JSON, 64 KiB at most). The server verifies that the sha256 of the canonical JSON
(section 12.1) equals the path (else 400 `bad_request`), keeps it in memory (LRU of 16) and answers `204`. Sent only when `ASR_SEND_VOCAB` is
on (and the policy `send_vocab` for the engine kind allows it).

### 5.5 POST /v1/chunk

Body = raw little-endian int16 PCM, mono, 16000 Hz, `Content-Type: application/octet-stream`.

```
X-MCAP-Samples: <n>          # Content-Length must equal 2*n; n <= limits.max_chunk_samples
X-MCAP-Lang:    ko | en | auto
X-MCAP-Langs:   ko,en        # restriction set for auto
X-MCAP-Vocab:   <sha256>     # optional; 404 vocab_unknown -> client PUTs it and retries once
X-MCAP-Prompt:  frame+list | list | none    # the server builds the prompt with its own tokenizer and runs asr.decode_chunk (prompt retry, echo guard)
X-MCAP-Chunk:   <track>:<index>             # accounting only
```

Response `200 application/json`:

```json
{"proto":"mcap-asr/1","op":"transcribe","engine":"whisper","model":"mlx-community/whisper-large-v3-mlx@49e6aa28","language":"ko",
 "text":"...","avg_logprob":-0.21,"truncated":false,"prompt_text":"다음은 한국어와 영어가 섞인 의료 AI 회의입니다. 용어: ...",
 "segments":[{"start":0.0,"end":3.2,"text":"...","avg_logprob":-0.21,"no_speech_prob":0.01,"compression_ratio":1.3,"temperature":0.0}]}
```

`prompt_text` feeds the client's `prompt_echo` guard. Segment times are relative to the chunk start; the client adds the chunk start, clamps
to the chunk end and runs its own `postfilter`, `suppress_echo` and alias steps (server output is raw). For `confidence:"opaque"` backends
the three numeric fields (`avg_logprob`, `no_speech_prob`, `compression_ratio`) are null.

### 5.6 POST /v1/lid (batch language ID)

Body = the clips' int16 PCM concatenated. `X-MCAP-Clips: n1,n2,...,nk` (sample counts, k <= `max_lid_clips`, each <= `max_lid_clip_samples`
i.e. 6 s, `Content-Length` = 2 * sum), `X-MCAP-Langs: ko,en`.

Response:

```json
{"proto":"mcap-asr/1","op":"lid","results":[{"ko":0.97,"en":0.03,"top":"ko"}]}
```

one entry per clip, restricted to the languages and renormalised, like `restrict_lid`. The client splits `detect_languages` into requests of at
most 12 clips and trims each clip to its centre 6 s. Clip seconds count against the audio quota.

### 5.7 POST /v1/purge

Flushes the in-memory idempotency cache and vocabulary entries of the calling token. `200 {"purged":N}`.

## 6. Errors

`{"error":{"code":"<code>","message":"<fixed one line, no content>","retry_after_s":N}}`. The client never copies server text into its own
messages: it keeps the HTTP status and the `code` only (an error text from a server must not be able to carry content, a canary or a token
into state, logs, usage records or notifications).

| HTTP | code | meaning | client |
|---|---|---|---|
| 400 | bad_request | header/length mismatch, bad PCM size, vocab digest mismatch, forbidden header | no retry |
| 401 | unauthorized | missing/unknown/revoked/expired token | `EngineAuthError`, circuit opens for the run |
| 401 | enroll_invalid | wrong, used or expired enrollment code | no retry |
| 403 | forbidden | token disabled, server policy | `EngineAuthError` |
| 404 | vocab_unknown | `X-MCAP-Vocab` not on the server | PUT vocab, retry once |
| 408 | request_timeout | body not received in 30 s | retry as 5xx |
| 409 | idem_conflict | same `X-MCAP-Idem`, different body | no retry (client bug) |
| 411 | length_required | no Content-Length | no retry |
| 413 | payload_too_large | more than the limits | no retry |
| 415 | unsupported_media_type | | no retry |
| 422 | unprocessable_audio | | no retry, chunk fails |
| 426 | proto_mismatch | body lists supported protocols | `EnginePolicyDenied` |
| 429 | quota_exceeded / enroll_throttled | per-token rpm, concurrency, daily seconds | honour Retry-After (<= `ASR_REMOTE_MAX_WAIT_S`), then `EngineTransient` |
| 500 | engine_error | backend failure | one retry |
| 503 | busy | queue full or predicted wait > `max_wait_s` (answered at once, the connection is not held) | honour Retry-After, then `EngineTransient` |
| 504 | engine_timeout | | one retry |

Statuses not in the table (clarification): a 5xx is handled like 500 (one retry), any other 4xx is a no-retry failure of that chunk. A
connection error, a TLS error or a timeout on the client side is `EngineTransient` after the attempts of section 7. `Retry-After` is the
HTTP header in seconds and is repeated as `retry_after_s` in the body.

## 7. Retry and idempotency

Client: up to `ASR_RETRY_MAX` (3) attempts per chunk; it waits `Retry-After` for 429/503 (cap 60 s each, total cap `ASR_REMOTE_MAX_WAIT_S`),
otherwise 1.0 s and 2.5 s with +-20% jitter (clock and random are injected in tests); 4xx are never retried except `vocab_unknown`. The same
`X-MCAP-Idem` is reused for every attempt of one request, and the lane gate (is the meeting still allowed to send?) is re-read before EVERY
attempt, including after a `Retry-After` sleep: a meeting switched to local-only while the client waits sends nothing more. The client
request timeout (`ASR_REQUEST_TIMEOUT_S`, 90 s) exceeds the server's queue cap (45 s) plus service time, so a healthy but busy server is
never timed out and recomputed.

Server: an in-memory LRU of the last 256 responses per token for 120 s answers a repeated key (token id, `X-MCAP-Idem`, sha256 of the body)
without recomputing, and a second request with the same key while the first is still running attaches to the running computation. The same
`X-MCAP-Idem` with a different body is `409 idem_conflict`. This cache is the only place transcript text exists after the response; it is memory
only and listed in `retention.memory_cache_s`.

## 8. Quotas (chunk level)

Per token: at most 2 requests in flight, 120 requests per minute, 43,200 audio seconds (12 h) per local day (chunks and LID clips both count).
Global: one engine worker, a fair queue (round robin over tokens), `max_queue` 64; `503 busy` with `Retry-After = ceil(depth x avg_service_s)` as
soon as the predicted wait exceeds `limits.max_wait_s` (45 s). Counters are rebuilt from the metadata log at start. The client has its own
advisory daily cap (`ASR_CLOUD_DAILY_MINUTES`, the policy cap); the server's per-token counters are the authoritative ones.

## 9. Retention and proof

There is no stored object: audio is request body in memory only, freed after the response; nothing is spooled; core dumps are disabled.
Hence no TTL, no ack-delete, no per-job keys. Evidence:

1. `health.retention` and `health.attest` (self-reported; not proof against a compromised server);
2. the client reads health at the start of every run and in `mcap asr-engines check`, refusing on `retention.mode != "none"`, a backend kind
   mismatch or a build hash outside the policy allow list;
3. quarterly `python -m mcap.asr_server audit` scans the service user's home and log directory for audio signatures and non-metadata log content.

Relay backends disclose the onward vendor in `health.vendor`; the vendor's retention claim is the vendor's (unverified).

## 10. Metadata log (server, content-free jsonl)

`{"ts","user","token_id","op","samples","audio_s","status","queue_ms","dur_ms","engine","bytes_in","src_net","machine_changed"}`; never audio,
text, file names, titles, session ids, tokens, or client addresses beyond a coarse source network. Retention `metadata_log_days` (default 400,
an administrator decision). `audit --daily` summarises new source networks, audio-hour spikes and machine changes from it.

## 11. Versioning

`X-MCAP-Proto: mcap-asr/1` is mandatory; a server that does not speak it answers 426 with `{"supported":["mcap-asr/1"]}`. `mcap-asr/2`
(whole-track upload, server-side VAD/AEC, DELETE ack, TTL) is reserved and not built; it would be the place for TTL, ack and job quotas. It
would be started only if the echo-suppression quality of chunk-level engines turns out worse than local by the pre-registered margin, or a
vendor needs longer context.

## 12. Clarifications both sides must implement identically

These are the points the design text leaves implicit. They are fixed here so that the client and the server, written independently, agree.

### 12.1 Canonical JSON of the vocabulary (the `{sha256}` of `PUT /v1/vocab`)

The digest is the lowercase hex SHA-256 of the UTF-8 bytes of the canonical form of the body object: `json.dumps(obj, ensure_ascii=False,
separators=(",", ":"), sort_keys=True)` (no whitespace, object keys sorted, non-ASCII characters not escaped, the order of `terms` kept).
The client sends exactly those bytes; the server parses the body, canonicalises it the same way and compares. Test vectors:

```
{"terms":["Acme","AcmeScan-CXR"]}   87ed861a28a3224008a330d64606c77606bc4c71f41b3c7d92a359ac0bb69070
{"terms":["액미","PACS"]}            5be960d3f9c4edcc23a746cdae69aad23fec5bd27566ea6635b52606bd95d012
```

### 12.2 `X-MCAP-Prompt`

The server builds the prompt with its own tokenizer, the way `asr.build_asr_prompt` does locally (terms in file order while they fit the token
budget, written in reverse so the most important term comes last):

- `frame+list`: the language frame, then the term list. The frames are the ones of the local Whisper engine (`ko`: the Korean medical-AI
  meeting sentence ending in `용어: `, `en`: `A medical AI meeting. Terms: `);
- `list`: the bare comma-separated term list (any language without a frame);
- `none`: no prompt (the client also sends `none` when it sends no vocabulary).

A backend with `uses_prompt=false` (opaque cloud backends) ignores the header. `prompt_text` in the response is the prompt that was actually used
(empty when none), so the client's echo guard can drop a segment that merely repeats it.

### 12.3 Languages

`X-MCAP-Lang: ko` or `en` forces that language; `auto` lets the backend decide, restricted to `X-MCAP-Langs` when the backend can restrict (a
backend with `supports_lid=false` accepts `auto` and reports the language it found in the response). The client calls `/v1/lid` only when
`health.supports_lid` is true; on a backend with `supports_lid=false` the call is `400 bad_request` (no retry), and the client then uses its
existing single-label path.

### 12.4 Times, counts and units

All segment times are seconds relative to the start of the chunk, as floats. `X-MCAP-Samples` and `X-MCAP-Clips` count samples, not bytes.
`audio_s` in the metadata log is `samples / 16000`. A chunk or clip over its limit is `413`. Unknown JSON fields in a response are ignored by
the client; missing optional fields (`avg_logprob`, `no_speech_prob`, `compression_ratio`, `prompt_text`, `temperature`) mean "not available",
never zero.

### 12.5 `X-MCAP-Machine`, `X-MCAP-Run`, `X-MCAP-Chunk`

`X-MCAP-Machine` is the first 16 hex characters of `sha256(machine id)` (the same machine id that binds the local consent file); it is a soft
binding for audit only. `X-MCAP-Run` is 16 random hex characters per pipeline run. `X-MCAP-Chunk` is `<track>:<index>` where track is `mic` or
`remote` and index counts chunks of the track from 0; neither is stored beyond the content-free metadata log.

## 13. Conformance checklist

Server:

- [ ] TLS (or loopback bind behind a terminator); refuses a non-loopback plaintext bind at start.
- [ ] Bearer check on every endpoint except `GET /v1/health` (no detail) and `POST /v1/enroll`; SHA-256 token table, constant-time compare, mtime re-read.
- [ ] Header and length validation before the body is read; `Transfer-Encoding`, duplicate `Content-Length`, `Expect`, `Upgrade` rejected.
- [ ] One engine worker, per-token round-robin queue, `503 busy` at once when the predicted wait exceeds 45 s.
- [ ] Idempotency cache keyed by (token, `X-MCAP-Idem`, body sha256), memory only, 120 s, in-flight merge; `409` on a key reuse with a different body.
- [ ] Per-token limits: 2 in flight, 120 per minute, 12 audio hours per local day; counters restored from the metadata log.
- [ ] Output of the Whisper backend produced through `asr.decode_chunk` (same prompt-retry and echo-guard heuristics as the local path).
- [ ] No audio, text, token or client address on disk, in a log or in an exception trace; startup self-check (no spool, `RLIMIT_CORE=0`, log directory 0700).
- [ ] `health` reports the truth about `kind`, `retention`, `attest`, `vendor`.

Client:

- [ ] Only the consented host and port, https, no redirects, no proxy or CA environment variables, a CA pinned by hash for server-kind hosts.
- [ ] Reads health first and refuses on a protocol, retention, backend-kind or attest mismatch.
- [ ] Re-reads the lane gate before every attempt; sends nothing for a local-only meeting.
- [ ] Reuses `X-MCAP-Idem` across retries; honours `Retry-After` within the caps; never copies server text into its own messages.
- [ ] Token only from the host-bound Keychain item; renews at 14 days or less; never persists it anywhere else.
