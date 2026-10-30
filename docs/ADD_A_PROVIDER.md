# Adding a cloud speech provider

A provider is a cloud speech-to-text service that takes a block of speech over https with one API key. `clova` (NAVER CLOVA Speech) and `openai-compat` (any server with an OpenAI-style `/audio/transcriptions`) ship. Another vendor is **one adapter class plus one registry entry** (and its row in the policy table). Already there, and not repeated per vendor:

- the destination bound into the typed consent and the Keychain item, the egress guard (https only, no redirects, exactly the consented host and port), the lane gate before every attempt, the daily cap and the content-free usage line (`asr_http.HttpEngine`);
- retries with `Retry-After` and the error mapping: 401/403 `EngineAuthError`, 429 and 5xx `EngineTransient`, another 4xx a chunk-local `EngineHttpError`, a closed gate or a redirect `EnginePolicyDenied`; messages are fixed sentences, never server text;
- the router with its circuit breaker and fallback, `mcap asr-engines list | check | consent | secret | revoke`, `mcap doctor`;
- blocks: the pipeline joins the VAD chunks of a track into blocks of `ASR_CLOUD_BLOCK_SECONDS`, calls `transcribe_chunk` once per block and maps the segment times back (`asr.pack_blocks`, `asr.block_times`, mixin `asr_engines.BlockUpload`). A 413 for a block makes the next ones shorter, and a block that only the primary could take is decoded chunk by chunk (`EngineBlockDeclined`, `asr.split_block`).

## The pieces

1. **Adapter**, `pipeline/mcap/asr_acme.py`: an `HttpEngine` with two pure functions, below.
2. **Registry entry**, `PROVIDERS["acme"]` in `asr_providers.py`: `name` (the engine id everywhere), `kind="cloud"`, `adapter="mcap.asr_acme:AcmeEngine"`, `url_setting` (the config key that names the destination), `settings`, `secret` (`required` or `optional`), `host_suffixes` (`()` when the user picks the host), `max_block_s` (the longest block the service takes, `0` for the global limit) and optionally `consent`, a function returning the consent lines this provider words itself. `asr_engines.REGISTRY`, the `ASR_ENGINE` / `ASR_FALLBACK` choices and the CLI read the entry; nothing else names the engine.
3. **Policy row**, `ENGINE_META["acme"]` in `policy.py`: `kind` `cloud`, `lane` `asr_cloud`, `backend_kind` `cloud`, `status` `ready`, `protocol` and `model` (a consent binds both), `residency` (a country code only when the service really processes the audio there; `foreign` when unknown or user-chosen), `max_request_bytes` / `max_response_bytes` (the defaults fit a 28 s chunk, not a block) and `destination` when the user picks the host.
4. **Config keys**: a `Config` field and a `_KEYS` row in `config.py`, a row in `docs/CONFIGURATION.md` and `README.ko.md`, a commented line in `config/config.env.example` (`scripts/test_scripts.sh` checks they agree). Provider keys stay out of `policy.DEFAULTS_WHITELIST`: a policy restricts, it does not set a vendor URL.
5. **Fixtures and tests**: `pipeline/tests/fixtures/acme/*.json`, `test_asr_acme.py`, modelled on `test_asr_clova.py`.

## Adapter skeleton

```python
class AcmeEngine(BlockUpload, HttpEngine):        # BlockUpload: one request per block (leave it out for 28 s chunks)
    engine_id, kind, residency = "acme", "cloud", "kr"
    uses_prompt, confidence = False, "opaque"     # "logprob" only for real log-probabilities

    def __init__(self, cfg, vocab, decision, guard, **kw):
        super().__init__(cfg, vocab, decision, guard, **kw)
        self._base = asr_providers.base_path(cfg, self.engine_id)    # the path of the URL setting; host and port are the consent's

    def load(self):
        self._require_consented_destination()     # the settings still name the consented host, else nothing is sent
        super().load()

    def auth_headers(self):                       # the default is "Authorization: Bearer <key>"
        self._require_consented_destination()     # before the Keychain is read
        return {"X-Acme-Key": self.secret()}

    def build_request(self, chunk, language):     # PURE: (method, path starting with "/", headers, body); chunk = float32 mono 16 kHz
        body, ctype = multipart_form([("file", "block.wav", "audio/wav", wav16(chunk))])
        return "POST", self._base + "/v1/transcribe", {"Content-Type": ctype}, body

    def parse_response(self, status, body):       # PURE, called for a 2xx answer only
        doc = json.loads(body)                    # unusable -> EngineTransient with a FIXED message, never an empty transcript
        rows = [{"start": s["from"], "end": s["to"], "text": s["text"], "confidence": None} for s in doc["segments"]]
        return {"text": doc["text"], "language": "ko", "avg_logprob": None, "truncated": False, "segments": merge_segments(rows, MAX_SEGMENTS)}
```

Times are seconds from the start of the block. `clean_result` keeps the first `MAX_SEGMENTS` (200) segments of an answer, so `merge_segments` joins neighbours instead of losing the tail. Never put server text into an exception, a log line or a file.

## Checklist

- [ ] **Consent text.** `mcap asr-engines consent acme` names the host, what is sent (block length, file name, vocabulary or not), retention as the vendor's claim, and billing. Differences from the generic text go in the entry's `consent` function; for a destination the user chose, say so.
- [ ] **ENGINE_META** with the right `residency` (it decides `allow_foreign`), `protocol`, `model` and byte limits.
- [ ] **Destination.** `host_suffixes` for fixed gateways; `()` only when the user picks the host. The `load()` / `auth_headers()` checks above.
- [ ] **Fixtures** written from the vendor's documentation, each with a `_fixture` header (`origin` `document-derived`, `verified` false, "the first live call confirms the shape"); invented text only. Replace them with recorded answers after that call.
- [ ] **Tests, no network:** request bytes, the parser (documented fields, empty and malformed answers), the error mapping (401/403, 429 with `Retry-After`, 5xx, other 4xx, a failed job), the destination (https only, suffixes, no redirect, settings edited after the decision), a canary that the key, your domain and server text never reach a log, state file, usage line or transcript, the usage line and provenance of a block, one pass through `transcribe_tracks` behind the router.
- [ ] **Not in the adapter:** no socket, no Keychain call except `self.secret()`, no file, no host in `transcript.json` (provenance carries the label `acme`).
