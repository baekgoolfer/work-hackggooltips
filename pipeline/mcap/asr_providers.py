"""The registry of the cloud ASR providers (SPEC 18): what a vendor needs besides its adapter class.

A provider is an ``asr_http.HttpEngine`` adapter of kind ``cloud`` that sends a block of speech to one https endpoint with one API key.
Adding a vendor is ONE adapter class plus ONE entry in ``PROVIDERS`` (and its row in ``policy.ENGINE_META``; the checklist is
docs/ADD_A_PROVIDER.md). Everything else is generic and already there: the destination is bound into the typed consent and the Keychain item
(``policy.consent_binding`` asks ``target`` below), the request goes through the ``EgressGuard`` (https only, no redirects, the one consented
host), the lane gate, the daily cap and the content-free usage line are ``HttpEngine``'s, ``mcap asr-engines list | check | consent | secret``
read the entry, and ``asr_engines.REGISTRY`` takes the adapter path from it.

Nothing here opens a socket, reads the Keychain or touches a file, and the module imports only the standard library (policy.py and the
CLI read it without loading numpy or an HTTP stack). The helpers at the end are the pure pieces two adapters share: the multipart body,
the cut of a long answer, a language guess for a vendor that does not name the language of a segment.

Two providers ship: ``clova`` (NAVER CLOVA Speech, long-sentence upload API) and ``openai-compat`` (any server with an OpenAI-style
``POST <base>/audio/transcriptions``; the user decides which vendor or self-hosted server sits behind it).
"""
from __future__ import annotations

import hashlib
import ipaddress
import math
import re
from dataclasses import dataclass
from typing import Any, Callable, Optional, Sequence
from urllib.parse import urlsplit

BLOCK_SECONDS_RANGE = (30, 1800)        # ASR_CLOUD_BLOCK_SECONDS: config.py checks the same range; 1800 s of WAV is 57.6 MB, the 64 MiB of policy.ENGINE_META
CLOVA_HOST_SUFFIXES = (".ncloud.com", ".fin-ncloud.com", ".gov-ncloud.com")   # the NAVER Cloud gateways (public, finance, government)
MAX_PATH_CHARS = 200
OPENAI_MAX_BLOCK_S = 720                # 720 s of 16 kHz mono WAV are 23.04 MB: under the 25 MB upload limit OpenAI documents (and gateways in front of other servers copy)

_LABEL = r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
_DNS_NAME = re.compile(rf"{_LABEL}(\.{_LABEL})+\Z")
_PATH = re.compile(r"(/[A-Za-z0-9._~%+=@:,-]+)*\Z")                 # printable path characters only, no empty segment
HANGUL = re.compile("[ㄱ-ㆎ가-힣]")


@dataclass(frozen=True)
class Provider:
    """One entry of ``PROVIDERS``. ``name`` is the engine id everywhere: the value of ``ASR_ENGINE`` / ``ASR_FALLBACK``, the key of
    ``policy.ENGINE_META`` and ``asr_engines.REGISTRY``, the Keychain service ``MeetingCapture ASR <name>``."""
    name: str
    kind: str                       # "cloud": the only kind a provider can have (a company server speaks mcap-asr/1: asr_remote)
    adapter: str                    # "module:Class", imported when the engine is used
    url_setting: str                # config.env key that names the destination; the Config field is its lower-case spelling
    settings: tuple                 # every config.env key of the provider, the URL first (what ``mcap asr-engines list`` shows)
    secret: str                     # "required" | "optional": the API key lives in the Keychain (``mcap asr-engines secret set <name>``)
    host_suffixes: tuple = ()       # () = a host the user chose; otherwise the host must end in one of these (a leading dot)
    consent: Optional[Callable[[Any, dict, bool], dict]] = None   # (cfg, binding, sends_vocab) -> replacement lines of the consent text
    max_block_s: int = 0            # the longest block (seconds of speech) the service takes, whatever ASR_CLOUD_BLOCK_SECONDS says; 0 = the global range


def _setting(cfg: Any, key: str) -> Any:
    return getattr(cfg, key.lower(), "")


# ---------------------------------------------------------------------------------- the destination
def split_base(url: Any, suffixes: Sequence[str] = ()) -> tuple:
    """``(host, port, path)`` of a provider URL, or ``ValueError("not-configured" | "bad-host")``. https only, a plain lower-case ASCII DNS name
    (never an IP address, a trailing dot, user info), no query, fragment or parameters (a key must never travel in a URL), a path of printable
    characters without empty or dot segments; the host must end in one of ``suffixes`` when there are any. ``path`` has no trailing slash
    ('' for none). The host and port are what the consent and the Keychain item bind; the path is the user's own business (a CLOVA domain,
    ``/v1``)."""
    text = str(url or "").strip()
    if not text:
        raise ValueError("not-configured")
    try:
        parts = urlsplit(text)
        host, port = (parts.hostname or "").lower(), parts.port if parts.port is not None else 443
    except ValueError:
        raise ValueError("bad-host") from None
    if (not 0 < port < 65536 or parts.scheme != "https" or not host or parts.username or parts.password or parts.query or parts.fragment
            or "?" in text or "#" in text or any(ch.isspace() or ord(ch) < 32 for ch in text) or not host.isascii() or not _DNS_NAME.fullmatch(host)):
        raise ValueError("bad-host")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError("bad-host")                                   # an IP literal is never a server name
    if suffixes and not any(host.endswith(suffix) and len(host) > len(suffix) for suffix in suffixes):
        raise ValueError("bad-host")
    path = parts.path.rstrip("/")
    if len(path) > MAX_PATH_CHARS or not _PATH.fullmatch(path) or any(seg in (".", "..") for seg in path.split("/")):
        raise ValueError("bad-host")
    return host, port, path


def target(cfg: Any, engine: str) -> tuple:
    """``((host, port), None)`` or ``(None, "not-configured" | "bad-host")``: the destination ``policy.consent_binding`` binds a consent to.
    An engine that is not a provider (a stub: ``google``) is ``not-configured``."""
    provider = PROVIDERS.get(engine)
    if provider is None:
        return None, "not-configured"
    try:
        host, port, _path = split_base(_setting(cfg, provider.url_setting), provider.host_suffixes)
    except ValueError as exc:
        return None, str(exc)
    return (host, port), None


def base_path(cfg: Any, engine: str) -> str:
    """The path part of the provider's URL setting ('' when it has none or the URL is not usable): what the adapter puts in front of its
    own request path."""
    provider = PROVIDERS[engine]
    try:
        return split_base(_setting(cfg, provider.url_setting), provider.host_suffixes)[2]
    except ValueError:
        return ""


# ---------------------------------------------------------------------------------- what the CLI shows
def setup_hint(engine: str) -> Optional[str]:
    """The setting to write into config.env first, for the 'not configured' messages of the CLI (None for an engine that is not a provider)."""
    provider = PROVIDERS.get(engine)
    return f"{provider.url_setting} (an https URL)" if provider is not None else None


def settings_summary(cfg: Any, engine: str) -> str:
    """The settings of ``engine`` as one content-free phrase for ``mcap asr-engines list``: the URL setting as ``set`` / ``not set`` (it may
    carry the id of a user's domain: never printed), the others with their value. ``-`` for an engine that is not a provider."""
    provider = PROVIDERS.get(engine)
    if provider is None:
        return "-"
    bits = []
    for key in provider.settings:
        value = _setting(cfg, key)
        if key == provider.url_setting:
            bits.append(f"{key} " + ("set" if str(value or "").strip() else "not set"))
        else:
            bits.append(f"{key}={value}")
    return ", ".join(bits)


def secret_note(engine: str) -> str:
    """``required`` | ``optional`` | ``none``: whether the engine needs an API key (``none`` for a non-provider)."""
    provider = PROVIDERS.get(engine)
    return provider.secret if provider is not None else "none"


def consent_overrides(cfg: Any, binding: dict, sends_vocab: bool) -> dict:
    """The lines of ``mcap asr-engines consent`` that a provider words itself (keys ``destination``, ``sends``, ``vocab``, ``price``; any may
    be missing: the generic line stays). ``{}`` for an engine that is not a provider. The host is always named."""
    provider = PROVIDERS.get(binding.get("engine"))
    if provider is None or provider.consent is None:
        return {}
    return provider.consent(cfg, binding, sends_vocab)


def block_seconds(cfg: Any, engine: str) -> float:
    """The length of one upload block of ``engine`` in seconds: ``ASR_CLOUD_BLOCK_SECONDS`` within ``BLOCK_SECONDS_RANGE`` and within the
    ``max_block_s`` of the provider (its service refuses a longer upload: OpenAI's own limit is 25 MB, which is 780 s of 16 kHz WAV). A value
    that is not a finite number reads as 900."""
    low, high = BLOCK_SECONDS_RANGE
    provider = PROVIDERS.get(engine)
    if provider is not None and provider.max_block_s:
        high = min(high, provider.max_block_s)
    value = getattr(cfg, "asr_cloud_block_seconds", 900)
    seconds = float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else 900.0
    return float(min(max(seconds, low), high))


def _clova_consent(cfg: Any, binding: dict, sends_vocab: bool) -> dict:
    block = int(block_seconds(cfg, "clova"))
    return {
        "destination": f"  보내는 곳:   {binding['host']}:{binding['port']} (NAVER Cloud CLOVA Speech). 호스트와 포트만 동의에 묶이고, 인보크 URL의 경로(도메인 식별자)는 묶이지 않습니다.",
        "sends": f"  보내는 것:   에코 제거 후 발화 구간만 이어 붙인 음성 블록(16 kHz mono WAV, 한 번에 최대 {block}초, 파일명 block.wav). "
                 "제목, 세션 ID, 플랫폼, 참석자는 보내지 않습니다.",
        "vocab": (f"  용어집:      ASR_SEND_VOCAB가 켜져 있어 vocabulary.txt의 용어(한 글자 용어 제외, 최대 1000개)가 boostings로 함께 전송됩니다."
                  if sends_vocab else "  용어집:      용어는 전송하지 않습니다 (ASR_SEND_VOCAB 꺼짐 또는 정책이 제한)."),
        "price": "  단가 추정:   이 Mac은 금액을 추정하지 않습니다. CLOVA Speech는 요청마다 15초 단위로 올림해 과금하므로 블록 하나가 한 요청입니다. "
                 "청구는 사용자와 NAVER Cloud 사이의 일이고, 이 Mac은 호출마다 오디오 초만 asr-usage.jsonl에 남깁니다.",
    }


def _openai_compat_consent(cfg: Any, binding: dict, sends_vocab: bool) -> dict:
    block = int(block_seconds(cfg, "openai-compat"))
    model = str(getattr(cfg, "asr_openai_compat_model", "") or "").strip() or "(비어 있음)"
    return {
        "destination": f"  보내는 곳:   {binding['host']}:{binding['port']}  <- 사용자가 직접 정한 서버입니다 (ASR_OPENAI_COMPAT_URL). "
                       "이 호스트 뒤에 어떤 벤더나 서버가 있는지 이 Mac은 알지도 확인하지도 못하고, 음성은 그곳 운영자의 손에 넘어갑니다. "
                       "호스트와 포트만 동의에 묶이고, 경로와 모델 이름은 묶이지 않습니다.",
        "sends": f"  보내는 것:   에코 제거 후 발화 구간만 이어 붙인 음성 블록(16 kHz mono WAV, 한 번에 최대 {block}초, 파일명 block.wav)과 "
                 f"모델 이름({model}). 제목, 세션 ID, 플랫폼, 참석자는 보내지 않습니다.",
        "vocab": "  용어집:      이 엔진은 용어집을 보내지 않습니다.",
        "price": "  단가 추정:   이 Mac은 금액을 추정하지 않습니다. 청구는 사용자와 그 서버의 운영자 사이의 일이고, 이 Mac은 호출마다 오디오 초만 "
                 "asr-usage.jsonl에 남깁니다.",
    }


PROVIDERS: dict[str, Provider] = {
    "clova": Provider(
        name="clova", kind="cloud", adapter="mcap.asr_clova:ClovaEngine", url_setting="ASR_CLOVA_INVOKE_URL",
        settings=("ASR_CLOVA_INVOKE_URL", "ASR_CLOVA_LANGUAGE", "ASR_CLOVA_DIARIZATION"), secret="required",
        host_suffixes=CLOVA_HOST_SUFFIXES, consent=_clova_consent),
    "openai-compat": Provider(
        name="openai-compat", kind="cloud", adapter="mcap.asr_openai_compat:OpenAICompatEngine", url_setting="ASR_OPENAI_COMPAT_URL",
        settings=("ASR_OPENAI_COMPAT_URL", "ASR_OPENAI_COMPAT_MODEL"), secret="optional", consent=_openai_compat_consent,
        max_block_s=OPENAI_MAX_BLOCK_S),
}


# ---------------------------------------------------------------------------------- pure helpers of the adapters
def multipart_form(parts: Sequence[tuple]) -> tuple:
    """``(body, content_type)`` of a ``multipart/form-data`` request. ``parts`` are ``(name, filename or None, content_type or None, data)``;
    the order is kept, line ends are CRLF. The boundary is derived from the content, so one request has the same bytes on every attempt, and
    it is derived again in the (practically impossible) case that it occurs inside a part."""
    seed = hashlib.sha256(b"\0".join(bytes(part[3]) for part in parts)).hexdigest()
    while True:
        boundary = "mcap-" + seed[:32]
        marker = b"--" + boundary.encode("ascii")
        if not any(marker in bytes(part[3]) for part in parts):
            break
        seed = hashlib.sha256(seed.encode("ascii")).hexdigest()
    out = bytearray()
    for name, filename, content_type, data in parts:
        head = f'Content-Disposition: form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        if content_type:
            head += f"\r\nContent-Type: {content_type}"
        out += marker + b"\r\n" + head.encode("ascii") + b"\r\n\r\n" + bytes(data) + b"\r\n"
    out += marker + b"--\r\n"
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def merge_segments(segments: list, limit: int) -> list:
    """At most ``limit`` segments: when there are more, neighbours are joined in equal groups (the first start, the last end, the texts with a
    space, ``confidence`` the lowest of the group). ``HttpEngine.clean_result`` keeps only the first ``MAX_SEGMENTS`` segments of one answer
    and a block of a quarter of an hour can hold more: the text of the tail is never dropped, only its timing gets coarser."""
    if limit < 1 or len(segments) <= limit:
        return list(segments)
    group = -(-len(segments) // limit)
    merged = []
    for i in range(0, len(segments), group):
        part = segments[i:i + group]
        confidences = [s["confidence"] for s in part if s.get("confidence") is not None]
        merged.append({**part[0], "end": max(s["end"] for s in part), "text": " ".join(s["text"] for s in part),
                       "confidence": min(confidences) if confidences else None})
    return merged


def guess_language(text: str) -> Optional[str]:
    """``ko`` for text with a Hangul syllable or jamo, ``en`` for other text with a Latin letter, else None: for a service that mixes two
    languages in one request and does not say which one a segment is in."""
    if HANGUL.search(text):
        return "ko"
    return "en" if any(ch.isascii() and ch.isalpha() for ch in text) else None
