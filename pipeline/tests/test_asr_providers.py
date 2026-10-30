"""asr_providers.py (SPEC 18): the registry of the cloud ASR providers, its pure helpers, the settings of the providers (config.py, the example
file, the documentation) and what ``mcap asr-engines list | check | consent | secret`` say about them.

Pinned: a provider is ONE adapter class plus ONE entry (the entry, ``policy.ENGINE_META``, ``asr_engines.REGISTRY`` and the engine choices agree; a
made-up vendor works through every generic path with no other code), the destination rules of ``split_base`` (https only, a DNS name, no IP address,
no credentials / query / fragment, the host suffixes of a provider), the helpers (the multipart body, the cut of a long answer, the language guess),
the config keys (defaults, ranges, canonical spelling, documented everywhere the repository's own checks look), and the CLI: the listing with its
settings status that never shows a key or the user's domain, the static check, the live check with one synthetic tone, the consent text that names the
configured host, and the credential commands.

Run: python -m unittest discover -s pipeline/tests
"""
import dataclasses
import json
import logging
import re
import unittest
from pathlib import Path
from unittest import mock

from asr_support import MACHINE
from provider_support import (CLOVA_HOST, CLOVA_ID_PATH, CLOVA_KEY, CLOVA_URL, OAI_HOST, OAI_KEY, OAI_URL, FakeClova, FakeOpenAI, clova_consent,
                              oai_consent, parse_multipart)
from notes_cli_support import make_cfg
import test_cli_asr as tca

from mcap import asr_engines, asr_providers, cli, config, policy, status
from mcap.asr_engines import BlockUpload
from mcap.asr_http import HttpEngine
from mcap.asr_providers import PROVIDERS, Provider, guess_language, merge_segments, multipart_form, split_base
from mcap.config import Config, parse_env_text

logging.getLogger("mcap").addHandler(logging.NullHandler())

REPO = Path(__file__).resolve().parents[2]
PROVIDER_KEYS = ("ASR_CLOVA_INVOKE_URL", "ASR_CLOVA_LANGUAGE", "ASR_CLOVA_DIARIZATION", "ASR_OPENAI_COMPAT_URL", "ASR_OPENAI_COMPAT_MODEL",
                 "ASR_CLOUD_BLOCK_SECONDS")


# ======================================================================================================================
class RegistryTests(unittest.TestCase):
    def test_the_entries_the_policy_table_and_the_engine_registry_agree(self):
        self.assertEqual(sorted(PROVIDERS), ["clova", "openai-compat"])
        for name, provider in PROVIDERS.items():
            with self.subTest(name):
                self.assertEqual(provider.name, name)
                self.assertIn(name, policy.ENGINE_META)
                self.assertEqual(asr_engines.REGISTRY[name], provider.adapter)
                self.assertIn(name, policy.ASR_ENGINE_CHOICES)
                self.assertIn(name, policy.ASR_FALLBACK_CHOICES)
                self.assertEqual(config._KEYS["ASR_ENGINE"][1](name), name)
                self.assertEqual(config._KEYS["ASR_FALLBACK"][1](name.upper()), name)
        self.assertEqual(set(policy.ENGINE_META), set(asr_engines.REGISTRY))

    def test_the_adapter_of_each_entry_is_what_the_entry_says(self):
        for name, provider in PROVIDERS.items():
            with self.subTest(name):
                cls = asr_engines.engine_class(name)
                self.assertTrue(issubclass(cls, HttpEngine) and issubclass(cls, BlockUpload))
                self.assertEqual((cls.engine_id, cls.kind, provider.kind), (name, "cloud", "cloud"))
                self.assertEqual(cls.accepts_blocks, True)

    def test_the_policy_rows_of_the_providers(self):
        for name in PROVIDERS:
            meta = policy.ENGINE_META[name]
            self.assertEqual((meta["kind"], meta["status"], meta["lane"], meta["backend_kind"]), ("cloud", "ready", "asr_cloud", "cloud"), name)
            self.assertGreater(meta["max_request_bytes"], 2_500_000)                       # the HostRule default is sized for a 28 s chunk
            self.assertGreater(meta["max_response_bytes"], 262_144)
        self.assertEqual(policy.ENGINE_META["clova"]["residency"], "kr")
        self.assertEqual(policy.ENGINE_META["openai-compat"]["residency"], "foreign")

    def test_every_setting_of_an_entry_is_a_config_key_and_the_url_comes_first(self):
        for name, provider in PROVIDERS.items():
            self.assertEqual(provider.settings[0], provider.url_setting, name)
            for key in provider.settings:
                with self.subTest(key):
                    self.assertIn(key, config._KEYS)
                    self.assertTrue(hasattr(Config(), key.lower()))
        self.assertIn(provider_key_field := "asr_cloud_block_seconds", {f.name for f in dataclasses.fields(Config)})
        self.assertEqual(provider_key_field, config._KEYS["ASR_CLOUD_BLOCK_SECONDS"][0])

    def test_a_policy_layer_cannot_set_a_provider_key(self):
        # the Swift app pins DEFAULTS_WHITELIST against the Python one: the provider settings are the user's own config.env, never a company default
        for key in PROVIDER_KEYS:
            self.assertNotIn(key, policy.DEFAULTS_WHITELIST)

    def test_the_credential_of_a_provider_lives_where_the_other_engines_have_it(self):
        from mcap import asr_creds
        for name in PROVIDERS:
            self.assertEqual(asr_creds.service_name(name), f"MeetingCapture ASR {name}")
            self.assertEqual(asr_providers.secret_note(name), PROVIDERS[name].secret)
        self.assertEqual((asr_providers.secret_note("clova"), asr_providers.secret_note("openai-compat"), asr_providers.secret_note("remote")),
                         ("required", "optional", "none"))

    def test_a_vendor_is_one_entry_and_every_generic_path_takes_it(self):
        acme = Provider(name="acme", kind="cloud", adapter="mcap.asr_clova:ClovaEngine", url_setting="ASR_ACME_URL", settings=("ASR_ACME_URL",),
                        secret="required", host_suffixes=(".acme.example",))
        meta = {"kind": "cloud", "residency": "kr", "status": "ready", "lane": "asr_cloud", "protocol": "acme-1", "backend_kind": "cloud", "model": "m"}
        cfg = types_namespace(asr_acme_url="https://api.acme.example/v2")
        with mock.patch.dict(PROVIDERS, {"acme": acme}), mock.patch.dict(policy.ENGINE_META, {"acme": meta}):
            binding, why = policy.consent_binding(cfg, "acme")
            self.assertEqual((why, binding["host"], binding["port"], binding["protocol"], binding["model"], binding["region"]),
                             (None, "api.acme.example", 443, "acme-1", "m", ""))
            self.assertEqual(asr_providers.base_path(cfg, "acme"), "/v2")
            self.assertEqual(asr_providers.setup_hint("acme"), "ASR_ACME_URL (an https URL)")
            self.assertEqual(asr_providers.settings_summary(cfg, "acme"), "ASR_ACME_URL set")
            self.assertEqual(asr_providers.consent_overrides(cfg, binding, True), {})                    # no text of its own: the generic consent text applies
            self.assertEqual(policy.consent_binding(types_namespace(asr_acme_url="https://api.other.example/v2"), "acme"), (None, "bad-host"))
            self.assertEqual(policy.consent_binding(types_namespace(), "acme"), (None, "not-configured"))
        self.assertEqual(policy.consent_binding(cfg, "acme"), (None, "not-configured"))                  # gone with the patch

    def test_the_stub_and_the_local_engines_have_no_destination(self):
        cfg = Config()
        for engine in ("google", "whisper", "qwen3-asr"):
            self.assertEqual(policy.consent_binding(cfg, engine)[0], None, engine)
        self.assertEqual(asr_providers.target(cfg, "google"), (None, "not-configured"))
        self.assertEqual(asr_providers.setup_hint("remote"), None)
        self.assertEqual(asr_providers.settings_summary(cfg, "remote"), "-")

    def test_importing_the_registry_pulls_in_no_engine_and_no_third_party_module(self):
        import subprocess
        import sys
        code = ("import sys\nfrom mcap import asr_providers\nbad = [m for m in ('numpy', 'mcap.asr_http', 'mcap.asr_clova', 'mcap.asr_openai_compat', "
                "'mcap.egress', 'mcap.asr_creds') if m in sys.modules]\nprint(bad)\n")
        out = subprocess.run([sys.executable, "-c", code], cwd=REPO / "pipeline", capture_output=True, text=True, timeout=60)
        self.assertEqual(out.stdout.strip(), "[]", out.stderr)


def types_namespace(**kw):
    import types
    return types.SimpleNamespace(**kw)


# ======================================================================================================================
class DestinationTests(unittest.TestCase):
    def test_split_base(self):
        for url, expected in ((f"https://{CLOVA_HOST}{CLOVA_ID_PATH}", (CLOVA_HOST, 443, CLOVA_ID_PATH)), ("https://stt.example.org", ("stt.example.org", 443, "")),
                              ("https://stt.example.org/", ("stt.example.org", 443, "")), ("https://stt.example.org:8443/v1/", ("stt.example.org", 8443, "/v1")),
                              ("HTTPS://STT.EXAMPLE.ORG/V1", ("stt.example.org", 443, "/V1")), ("  https://a.example.org/x  ", ("a.example.org", 443, "/x")),
                              ("https://a.example.org/a-b_c.d~e%20f+g=h@i:j,k", ("a.example.org", 443, "/a-b_c.d~e%20f+g=h@i:j,k"))):
            with self.subTest(url):
                self.assertEqual(split_base(url), expected)

    def test_split_base_refuses(self):
        for url in ("http://a.example.org", "ftp://a.example.org", "a.example.org", "//a.example.org", "https://", "https:///x", "https://a", "https://a..example.org",
                    "https://-a.example.org", "https://a-.example.org", "https://a_b.example.org", "https://1.2.3.4", "https://1.2.3.4:8443/v1", "https://[::1]/",
                    "https://[2001:db8::1]:443/", "https://localhost", "https://user@a.example.org", "https://user:pw@a.example.org", "https://a.example.org/x?y=1",
                    "https://a.example.org/x?", "https://a.example.org/x#y", "https://a.example.org./x", "https://a.example.org/a//b", "https://a.example.org/a/./b",
                    "https://a.example.org/a/../b", "https://a.example.org/a b", "https://a.example.org/a\tb", "https://a.example.org/a;b", "https://a.example.org/a\\b",
                    "https://a.example.org\\@evil.example.net/x", "https://evil.example.net#@a.example.org/", "https://a.example.org:443@evil.example.net/",
                    "https://a.example.org:0", "https://a.example.org:70000", "https://a.example.org:http", "https://bücher.example.org", "https://a.example.org/한글",
                    "https://a.example.org/" + "x" * 250):
            with self.subTest(url):
                with self.assertRaises(ValueError) as ctx:
                    split_base(url)
                self.assertEqual(str(ctx.exception), "bad-host")

    def test_empty_is_not_configured_and_none_of_the_error_texts_carry_the_url(self):
        for value in ("", "   ", None):
            with self.assertRaisesRegex(ValueError, "^not-configured$"):
                split_base(value)
        with self.assertRaises(ValueError) as ctx:
            split_base("https://user:SECRET-TOKEN@a.example.org/x")
        self.assertNotIn("SECRET-TOKEN", str(ctx.exception))

    def test_host_suffixes(self):
        suffixes = (".ncloud.com", ".fin-ncloud.com")
        self.assertEqual(split_base("https://gw.ncloud.com/x", suffixes)[0], "gw.ncloud.com")
        self.assertEqual(split_base("https://gw.fin-ncloud.com/x", suffixes)[0], "gw.fin-ncloud.com")
        for url in ("https://ncloud.com/x", "https://gw.ncloud.com.evil.org/x", "https://gwncloud.com/x", "https://gw.example.org/x"):
            with self.subTest(url), self.assertRaises(ValueError):
                split_base(url, suffixes)

    def test_target_and_base_path_read_the_setting_of_the_provider(self):
        cfg = types_namespace(asr_clova_invoke_url=CLOVA_URL, asr_openai_compat_url=OAI_URL)
        self.assertEqual(asr_providers.target(cfg, "clova"), ((CLOVA_HOST, 443), None))
        self.assertEqual(asr_providers.target(cfg, "openai-compat"), ((OAI_HOST, 443), None))
        self.assertEqual((asr_providers.base_path(cfg, "clova"), asr_providers.base_path(cfg, "openai-compat")), (CLOVA_ID_PATH, "/v1"))
        self.assertEqual(asr_providers.target(types_namespace(asr_clova_invoke_url=OAI_URL), "clova"), (None, "bad-host"))     # not a NAVER Cloud host
        self.assertEqual(asr_providers.target(types_namespace(), "clova"), (None, "not-configured"))
        self.assertEqual(asr_providers.base_path(types_namespace(), "clova"), "")


# ======================================================================================================================
class HelperTests(unittest.TestCase):
    def parts(self, body, content_type):
        marker = b"--" + content_type.split("boundary=")[1].encode()
        pieces = body.split(marker)
        self.assertEqual((pieces[0], pieces[-1]), (b"", b"--\r\n"))
        return pieces[1:-1]

    def test_multipart_framing(self):
        body, ctype = multipart_form([("file", "a.wav", "audio/wav", b"RIFF\r\n--x\r\n"), ("model", None, None, b"m"), ("params", None, "application/json", b"{}")])
        self.assertTrue(ctype.startswith("multipart/form-data; boundary=mcap-"))
        first, second, third = self.parts(body, ctype)
        self.assertEqual(first, b'\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n--x\r\n\r\n')
        self.assertEqual(second, b'\r\nContent-Disposition: form-data; name="model"\r\n\r\nm\r\n')
        self.assertEqual(third, b'\r\nContent-Disposition: form-data; name="params"\r\nContent-Type: application/json\r\n\r\n{}\r\n')

    def test_the_same_content_is_the_same_bytes_and_the_boundary_never_occurs_in_a_part(self):
        parts = [("a", None, None, b"one"), ("b", "f", "audio/wav", b"two")]
        self.assertEqual(multipart_form(parts), multipart_form(list(parts)))
        self.assertNotEqual(multipart_form(parts)[1], multipart_form([("a", None, None, b"other")])[1])

    def test_a_boundary_that_occurs_in_a_part_is_derived_again(self):
        class Digests:                                         # sha256 that hands out two chosen digests: the first boundary collides with the data
            def __init__(self, *hexdigests):
                self.hexdigests = list(hexdigests)

            def __call__(self, data=b""):
                return mock.Mock(hexdigest=mock.Mock(return_value=self.hexdigests.pop(0)))

        clash = b"data with --mcap-" + b"a" * 32 + b" inside"
        with mock.patch.object(asr_providers.hashlib, "sha256", Digests("a" * 64, "b" * 64)):
            body, ctype = multipart_form([("file", "f.wav", "audio/wav", clash)])
        self.assertEqual(ctype, "multipart/form-data; boundary=mcap-" + "b" * 32)
        self.assertTrue(body.startswith(b"--mcap-" + b"b" * 32 + b"\r\n") and body.endswith(b"--mcap-" + b"b" * 32 + b"--\r\n"))
        self.assertIn(clash, body)

    def test_merge_segments_never_drops_text(self):
        def seg(i, conf=0.9):
            return {"start": float(i), "end": i + 0.5, "text": f"t{i}", "confidence": conf, "avg_logprob": None}

        few = [seg(i) for i in range(5)]
        self.assertEqual(merge_segments(few, 5), few)
        self.assertEqual(merge_segments(few, 0), few)
        merged = merge_segments([seg(i, 0.9 - i * 0.01) for i in range(10)], 4)
        self.assertEqual(len(merged), 4)                                                              # groups of 3, 3, 3, 1
        self.assertEqual([m["text"] for m in merged], ["t0 t1 t2", "t3 t4 t5", "t6 t7 t8", "t9"])
        self.assertEqual((merged[0]["start"], merged[0]["end"], merged[-1]["end"]), (0.0, 2.5, 9.5))
        self.assertAlmostEqual(merged[0]["confidence"], 0.88)                                         # the lowest of the group
        self.assertEqual(merge_segments([seg(0, None), seg(1, None), seg(2, None)], 1)[0]["confidence"], None)

    def test_guess_language(self):
        for text, expected in (("안녕하세요", "ko"), ("hello", "en"), ("OK 네", "ko"), ("ㅋㅋ", "ko"), ("1234 !?", None), ("", None), ("日本語", None), ("café", "en")):
            self.assertEqual(guess_language(text), expected, text)

    def test_settings_summary_shows_values_but_never_the_url(self):
        cfg = types_namespace(asr_clova_invoke_url=CLOVA_URL, asr_clova_language="ko-KR", asr_clova_diarization="auto")
        text = asr_providers.settings_summary(cfg, "clova")
        self.assertEqual(text, "ASR_CLOVA_INVOKE_URL set, ASR_CLOVA_LANGUAGE=ko-KR, ASR_CLOVA_DIARIZATION=auto")
        self.assertNotIn(CLOVA_ID_PATH, text)
        self.assertNotIn(CLOVA_HOST, text)
        self.assertEqual(asr_providers.settings_summary(types_namespace(asr_clova_invoke_url="  "), "clova")[:30], "ASR_CLOVA_INVOKE_URL not set, ")
        self.assertEqual(asr_providers.setup_hint("clova"), "ASR_CLOVA_INVOKE_URL (an https URL)")
        self.assertEqual(asr_providers.setup_hint("openai-compat"), "ASR_OPENAI_COMPAT_URL (an https URL)")


# ======================================================================================================================
class ConfigTests(unittest.TestCase):
    def load(self, text):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.env"
            path.write_text(text, encoding="utf-8")
            with mock.patch.dict(os.environ, {"MCAP_POLICY_PATH": str(Path(tmp) / "none.json")}):
                return config.load_config(path)

    def test_the_defaults_change_nothing(self):
        cfg = Config()
        self.assertEqual((cfg.asr_clova_invoke_url, cfg.asr_clova_language, cfg.asr_clova_diarization, cfg.asr_openai_compat_url, cfg.asr_openai_compat_model,
                          cfg.asr_cloud_block_seconds), ("", "enko", "auto", "", "whisper-1", 900))
        self.assertEqual((cfg.asr_engine, cfg.asr_fallback), ("whisper", "none"))

    def test_values_are_read(self):
        cfg = self.load("ASR_ENGINE=CLOVA\nASR_FALLBACK=whisper\nASR_CLOVA_INVOKE_URL= https://gw.ncloud.com/x/ \nASR_CLOVA_LANGUAGE=ko-kr\nASR_CLOVA_DIARIZATION=OFF\n"
                        "ASR_OPENAI_COMPAT_URL=https://stt.example.org/v1\nASR_OPENAI_COMPAT_MODEL= large-v3 \nASR_CLOUD_BLOCK_SECONDS=300\n")
        self.assertEqual((cfg.asr_engine, cfg.asr_fallback, cfg.asr_clova_invoke_url, cfg.asr_clova_language, cfg.asr_clova_diarization),
                         ("clova", "whisper", "https://gw.ncloud.com/x/", "ko-KR", "off"))
        self.assertEqual((cfg.asr_openai_compat_url, cfg.asr_openai_compat_model, cfg.asr_cloud_block_seconds), ("https://stt.example.org/v1", "large-v3", 300))
        self.assertEqual(cfg.config_warnings, ())
        self.assertEqual(self.load("ASR_ENGINE=openai-compat\nASR_FALLBACK=OpenAI-Compat\n").asr_engine, "openai-compat")

    def test_the_language_has_a_canonical_spelling_and_an_unknown_word_reads_as_enko_with_a_warning(self):
        for text, expected in (("ko-KR", "ko-KR"), ("KO-kr", "ko-KR"), ("en-us", "en-US"), ("ENKO", "enko"), ("ja", "ja"), ("zh-CN", "zh-cn"), ("zh-tw", "zh-tw")):
            self.assertEqual(self.load(f"ASR_CLOVA_LANGUAGE={text}\n").asr_clova_language, expected, text)
        cfg = self.load("ASR_CLOVA_LANGUAGE=klingon\n")
        self.assertEqual(cfg.asr_clova_language, "enko")
        self.assertTrue([w for w in cfg.config_warnings if w.startswith("ASR_CLOVA_LANGUAGE: unrecognised value 'klingon'")])

    def test_diarization_reads_auto_on_off(self):
        for text, expected in (("auto", "auto"), ("On", "on"), ("off", "off"), ("1", "auto"), ("maybe", "auto")):
            self.assertEqual(self.load(f"ASR_CLOVA_DIARIZATION={text}\n").asr_clova_diarization, expected, text)
        self.assertTrue(self.load("ASR_CLOVA_DIARIZATION=maybe\n").config_warnings)

    def test_the_block_length_is_a_number_from_30_to_1800(self):
        for value in ("30", "900", "1800"):
            self.assertEqual(self.load(f"ASR_CLOUD_BLOCK_SECONDS={value}\n").asr_cloud_block_seconds, int(value))
        for value in ("29", "1801", "0", "-5", "abc", "90.5", "nan"):
            with self.subTest(value), self.assertRaisesRegex(ValueError, "config.env: bad value for ASR_CLOUD_BLOCK_SECONDS"):
                self.load(f"ASR_CLOUD_BLOCK_SECONDS={value}\n")

    def test_empty_values_are_the_defaults(self):
        cfg = self.load("ASR_CLOVA_INVOKE_URL=\nASR_CLOVA_LANGUAGE=\nASR_CLOUD_BLOCK_SECONDS=\nASR_OPENAI_COMPAT_MODEL=\n")
        self.assertEqual((cfg.asr_clova_invoke_url, cfg.asr_clova_language, cfg.asr_cloud_block_seconds, cfg.asr_openai_compat_model), ("", "enko", 900, "whisper-1"))

    def test_the_example_file_lists_every_provider_key_commented_with_its_default(self):
        text = (REPO / "config" / "config.env.example").read_text(encoding="utf-8")
        values = parse_env_text(text)
        commented = dict(re.findall(r"^# ([A-Z][A-Z0-9_]+)=(.*?)(?:[ \t]+#.*)?$", text, re.M))
        defaults = {"ASR_CLOVA_INVOKE_URL": "", "ASR_CLOVA_LANGUAGE": "enko", "ASR_CLOVA_DIARIZATION": "auto", "ASR_OPENAI_COMPAT_URL": "",
                    "ASR_OPENAI_COMPAT_MODEL": "whisper-1", "ASR_CLOUD_BLOCK_SECONDS": "900"}
        for key, default in defaults.items():
            with self.subTest(key):
                self.assertNotIn(key, values)                                                         # commented out: the example changes nothing
                self.assertEqual(commented[key], default)
        cfg = config.load_config(REPO / "config" / "config.env.example")
        self.assertEqual((cfg.asr_clova_language, cfg.asr_cloud_block_seconds, cfg.asr_openai_compat_model), ("enko", 900, "whisper-1"))
        self.assertNotIn("sk-", text)

    def test_every_provider_key_is_in_the_documentation_tables_with_its_default(self):
        defaults = {"ASR_CLOVA_INVOKE_URL": "<", "ASR_CLOVA_LANGUAGE": "`enko`", "ASR_CLOVA_DIARIZATION": "`auto`", "ASR_OPENAI_COMPAT_URL": "<",
                    "ASR_OPENAI_COMPAT_MODEL": "`whisper-1`", "ASR_CLOUD_BLOCK_SECONDS": "`900`"}
        for doc in ("docs/CONFIGURATION.md", "README.ko.md"):
            text = (REPO / doc).read_text(encoding="utf-8")
            for key, default in defaults.items():
                with self.subTest(doc=doc, key=key):
                    row = re.search(rf"^\| `{key}` \| ([^|]*) \|", text, re.M)
                    self.assertIsNotNone(row, f"{doc} has no row for {key}")
                    self.assertTrue(row.group(1).strip().startswith(default), (doc, key, row.group(1)))
        english = (REPO / "README.md").read_text(encoding="utf-8")
        for key in ("ASR_ENGINE", "ASR_CLOVA_INVOKE_URL", "ASR_OPENAI_COMPAT_URL", "ASR_CLOUD_BLOCK_SECONDS"):
            self.assertIn(f"`{key}`", english, key)


# ======================================================================================================================
class PrivacyDocsTests(unittest.TestCase):
    """The pages that say what can leave the Mac name every external engine and what it receives (SECURITY.md: a path that is not in
    docs/PRIVACY_AND_CONSENT.md is a reportable leak)."""
    LABELS = {"remote": "company server", "azure": "Azure", "clova": "CLOVA", "openai-compat": "openai-compat"}

    def text(self, *parts) -> str:
        return REPO.joinpath(*parts).read_text(encoding="utf-8")

    def line(self, text: str, start: str) -> str:
        return next(line for line in text.splitlines() if line.startswith(start))

    def test_every_external_engine_has_a_label_here(self):
        external = {name for name, meta in policy.ENGINE_META.items() if meta["kind"] != "local" and meta["status"] == "ready"}
        self.assertEqual(external, set(self.LABELS))                  # a new engine must be added to this list, and so to the pages below

    def test_the_consent_page_names_every_engine_and_what_goes_to_it(self):
        row = self.line(self.text("docs", "PRIVACY_AND_CONSENT.md"), "| **Speech recognition**")
        for name, label in self.LABELS.items():
            self.assertIn(label, row, name)
        for part in ("API key", "model name", "boostings", "ASR_SEND_VOCAB", "ASR_CLOUD_BLOCK_SECONDS", "you** choose", "remote participants"):
            self.assertIn(part, row)

    def test_the_security_page_does_not_call_the_external_engines_an_organisation_only_feature(self):
        text = self.text("SECURITY.md")
        bullet = self.line(text, "- **Network.**")
        for label in ("CLOVA", "OpenAI-style", "personal install"):
            self.assertIn(label, bullet)
        self.assertNotIn("an opt-in of the experimental organisation mode", text)

    def test_the_lane_page_says_which_engine_gets_the_vocabulary(self):
        text = self.text("docs", "PRIVACY_LANES.md")
        section = text[text.index("### 2.2 vocabulary"):text.index("### 2.3")]
        self.assertIn("CLOVA `boostings`", section)
        self.assertIn("openai-compat", section)
        self.assertIn("asr.send_vocab.cloud", section)

    def test_the_policy_page_lists_every_engine_word_of_the_settings(self):
        row = self.line(self.text("docs", "POLICY.md"), "| A4 |")
        for word in (*policy.ASR_ENGINE_CHOICES, *policy.ASR_FALLBACK_CHOICES):
            self.assertIn(f"`{word}`", row, word)

    def test_the_readmes_say_the_vocabulary_leaves_with_clova(self):
        english = self.text("README.md")
        self.assertIn("the terms of your vocabulary list", self.line(english, "| Speech audio"))
        self.assertIn("as `boostings` while `ASR_SEND_VOCAB` is on", english)
        self.assertIn("`boostings`", self.line(self.text("README.ko.md"), "- **클라우드 음성 엔진(선택)**"))


# ======================================================================================================================
class DocsTests(unittest.TestCase):
    """docs/ADD_A_PROVIDER.md says what the code has: it must not drift from it."""

    def setUp(self):
        self.text = (REPO / "docs" / "ADD_A_PROVIDER.md").read_text(encoding="utf-8")

    def test_it_is_short_and_names_every_field_of_a_registry_entry(self):
        self.assertLess(len(self.text.split()), 900)                                              # "under two pages"
        for field in dataclasses.fields(Provider):
            self.assertIn(f"`{field.name}", self.text, field.name)

    def test_every_name_the_skeleton_uses_exists(self):
        from mcap import asr_http
        for name in ("base_path", "multipart_form", "merge_segments"):
            self.assertTrue(callable(getattr(asr_providers, name)), name)
            self.assertIn(name, self.text)
        self.assertTrue(callable(BlockUpload._require_consented_destination))
        self.assertTrue(callable(asr_http.wav16) and isinstance(asr_http.MAX_SEGMENTS, int))
        for name in ("_require_consented_destination", "BlockUpload", "HttpEngine", "MAX_SEGMENTS", "build_request", "parse_response", "auth_headers",
                     "ENGINE_META", "PROVIDERS", "asr_engines.REGISTRY"):
            self.assertIn(name, self.text, name)

    def test_the_checklist_covers_what_the_task_names(self):
        for word in ("Consent text", "ENGINE_META", "Fixtures", "Tests", "document-derived"):
            self.assertIn(word, self.text, word)

    def test_the_skeleton_is_valid_python_and_the_two_shipped_adapters_follow_it(self):
        import ast
        code = re.search(r"```python\n(.*?)```", self.text, re.S).group(1)
        ast.parse(code)
        for module in (asr_engines.engine_class("clova"), asr_engines.engine_class("openai-compat")):
            for method in ("build_request", "parse_response", "load", "auth_headers"):
                self.assertIn(method, vars(module), (module.__name__, method))


class LaneTests(unittest.TestCase):
    """The lane resolver of a run (lanes.py) in front of the providers."""

    def cfg(self, **kw):
        import tempfile
        root = Path(tempfile.mkdtemp(prefix="mcap-prov-"))
        self.addCleanup(__import__("shutil").rmtree, root, True)
        return make_cfg(root, asr_clova_invoke_url=CLOVA_URL, asr_openai_compat_url=OAI_URL, **kw)

    def test_a_resolved_run_carries_a_provider_decision_with_the_block_sized_limits(self):
        from mcap import lanes
        cfg = self.cfg(asr_engine="clova", asr_fallback="whisper")
        inputs = lanes.PrivacyInputs(policy=policy.absent_policy(), consents=policy.ConsentSet(entries=(clova_consent(),), machine=MACHINE),
                                     hw=tca.probe(), now=tca.NOW)
        privacy = lanes.resolve_run(cfg, None, None, inputs=inputs)
        self.assertEqual((privacy.asr.primary, privacy.asr.fallback, privacy.asr.allow_egress), ("clova", "whisper", True))
        self.assertEqual(privacy.asr.engine_hosts, {"clova": CLOVA_HOST})
        rule = privacy.asr.hosts[CLOVA_HOST]
        self.assertEqual((rule.max_request_bytes, rule.max_response_bytes), (64 << 20, 16 << 20))
        local_only = lanes.resolve_run(cfg, {"local_only": True}, None, inputs=dataclasses.replace(inputs, meeting={"local_only": True}))
        self.assertEqual((local_only.asr.primary, local_only.asr.allow_egress), ("whisper", False))

    def test_lanes_load_the_consent_file_when_a_provider_is_named(self):
        from mcap import lanes
        for engine in PROVIDERS:
            self.assertTrue(lanes._needs_consents(types_namespace(asr_engine=engine, asr_fallback="none")), engine)
            self.assertTrue(lanes._needs_consents(types_namespace(asr_engine="whisper", asr_fallback=engine)), engine)
        for engine in ("remote", "azure"):                                    # the engines of before keep working the same way
            self.assertTrue(lanes._needs_consents(types_namespace(asr_engine=engine, asr_fallback="none")), engine)
        self.assertTrue(lanes._needs_consents(types_namespace(asr_engine="auto", asr_fallback="none")))
        self.assertFalse(lanes._needs_consents(types_namespace(asr_engine="whisper", asr_fallback="none")))     # today's default reads no consent

    def test_a_resolved_run_reads_the_consent_file_of_the_provider_it_names(self):
        # No ConsentSet is handed in (PrivacyInputs.consents stays None): resolve_run loads asr-consent.json itself, as every real run does.
        from mcap import lanes
        for engine, entry in (("clova", clova_consent()), ("openai-compat", oai_consent())):
            for slot, kw in (("primary", {"asr_engine": engine, "asr_fallback": "whisper"}), ("fallback", {"asr_engine": "whisper", "asr_fallback": engine})):
                with self.subTest(engine=engine, slot=slot):
                    cfg = self.cfg(**kw)
                    inputs = lanes.PrivacyInputs(policy=policy.absent_policy(), hw=tca.probe(), now=tca.NOW)
                    with mock.patch.object(policy, "machine_id", return_value=MACHINE):
                        before = lanes.resolve_run(cfg, None, None, inputs=inputs)          # no consent file yet: the provider is excluded
                        policy.write_consent(cfg.consent_path, entry, machine_id=MACHINE)
                        after = lanes.resolve_run(cfg, None, None, inputs=inputs)
                    self.assertFalse(before.asr.allow_egress, (engine, slot))
                    self.assertTrue(after.asr.allow_egress, (engine, slot, after.asr.notes))
                    self.assertEqual((after.asr.primary, after.asr.fallback), (engine, "whisper") if slot == "primary" else ("whisper", engine))


class ProviderCliCase(tca.CliAsrCase):
    """The CLI against the providers: the config.env names both, the CLOVA key is in the fake Keychain, one transport answers for the three kinds of
    server (CLOVA, the OpenAI-style one, the relay of the base case)."""

    def write_config(self, **extra):
        """The config.env of the base case plus the two provider URLs (an empty value unsets one); ``extra`` wins."""
        super().write_config(**{"ASR_CLOVA_INVOKE_URL": CLOVA_URL, "ASR_OPENAI_COMPAT_URL": OAI_URL, **extra})

    def setUp(self):
        super().setUp()
        self.clova, self.oai = FakeClova(), FakeOpenAI()
        relay = self.transport.handler

        def route(call):
            host = call.rule.host
            return self.clova(call) if host == CLOVA_HOST else self.oai(call) if host == OAI_HOST else relay(call)

        self.transport.handler = route
        self.store_token(CLOVA_KEY, "clova", CLOVA_HOST)

    def row(self, engine):
        code, out, _err = self.mcap("asr-engines", "list", "--json")
        self.assertEqual(code, 0)
        return next(r for r in json.loads(out)["engines"] if r["engine"] == engine)

    def entries(self):
        return policy.load_consents(self.cfg.consent_path, machine_id=MACHINE, now=tca.NOW).entries


class ListTests(ProviderCliCase):
    def test_a_provider_that_is_not_configured_says_which_setting_to_write(self):
        self.write_config(ASR_CLOVA_INVOKE_URL="")
        row = self.row("clova")
        self.assertEqual((row["consent"], row["destination"], row["credential"], row["usable"]), ("not-configured", "-", "n/a", False))
        self.assertTrue(row["settings"].startswith("ASR_CLOVA_INVOKE_URL not set, ASR_CLOVA_LANGUAGE=enko"))

    def test_a_configured_provider_with_a_consent_and_a_key_is_usable_and_shows_no_secret(self):
        self.consent("clova", **dict(region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST))
        code, out, _err = self.mcap("asr-engines", "list")
        rows = {line.split()[0]: line for line in out.splitlines()[1:]}
        self.assertIn("settings", out.splitlines()[0])
        self.assertIn("ok (until 2027-10-14)", rows["clova"])
        self.assertIn("clova/default", rows["clova"])
        self.assertIn("stored", rows["clova"])
        self.assertIn("ASR_CLOVA_INVOKE_URL set", rows["clova"])
        self.assertTrue(rows["clova"].rstrip().endswith("yes"))
        row = self.row("clova")
        self.assertEqual((row["policy"], row["usable"], row["kind"], row["residency"], row["status"]), ("allowed", True, "cloud", "kr", "ready"))
        for needle in (CLOVA_KEY, CLOVA_ID_PATH, CLOVA_HOST, OAI_HOST):
            self.assertNotIn(needle, out)
        self.assertEqual(self.security.reads(), 0)                                                    # the key is asked about, never read
        self.assertEqual(self.transport.calls, [])

    def test_a_key_is_optional_for_the_openai_style_provider(self):
        self.consent("openai-compat", region="", model="", protocol="openai-audio-transcriptions", host=OAI_HOST)
        row = self.row("openai-compat")
        self.assertEqual((row["credential"], row["usable"], row["residency"], row["consent"][:2]), ("none (optional)", True, "foreign", "ok"))
        self.store_token(OAI_KEY, "openai-compat", OAI_HOST)
        self.assertEqual(self.row("openai-compat")["credential"], "stored")
        self.assertNotIn(OAI_KEY, self.mcap("asr-engines", "list")[1])

    def test_the_providers_are_in_the_listing_next_to_the_others(self):
        code, out, _err = self.mcap("asr-engines", "list")
        self.assertEqual([line.split()[0] for line in out.splitlines()[1:]], ["whisper", "qwen3-asr", "remote", "azure", "google", "clova", "openai-compat"])


class CheckTests(ProviderCliCase):
    def test_a_consented_provider_with_a_key_passes_without_a_request(self):
        self.consent("clova", region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST)
        code, out, _err = self.mcap("asr-engines", "check", "clova")
        self.assertEqual(code, 0, out)
        self.assertIn("clova (cloud, kr)", out)
        self.assertIn("a credential is stored (the value is not read)", out)
        self.assertIn("check: ok", out)
        self.assertEqual((self.transport.calls, self.security.reads()), ([], 0))
        self.assert_clean(out)
        self.assertNotIn(CLOVA_ID_PATH, out)

    def test_a_missing_key_fails_the_check_and_says_what_to_run(self):
        self.consent("clova", region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST)
        self.security.remove()
        code, out, _err = self.mcap("asr-engines", "check", "clova")
        self.assertEqual(code, 1)
        self.assertIn("no credential is stored for this destination", out)

    def test_a_missing_consent_fails_the_check_and_names_the_command(self):
        code, out, _err = self.mcap("asr-engines", "check", "clova")
        self.assertEqual(code, 1)
        self.assertIn("mcap asr-engines consent clova", out)

    def test_an_unconfigured_provider_names_its_own_setting(self):
        self.write_config(ASR_OPENAI_COMPAT_URL="")
        code, out, _err = self.mcap("asr-engines", "check", "openai-compat")
        self.assertEqual(code, 1)
        self.assertIn("set ASR_OPENAI_COMPAT_URL (an https URL) in config.env", out)
        self.assertNotIn("ASR_REMOTE_URL", out)

    def test_a_server_without_a_key_passes_and_the_check_says_the_key_is_optional(self):
        self.consent("openai-compat", region="", model="", protocol="openai-audio-transcriptions", host=OAI_HOST)
        code, out, _err = self.mcap("asr-engines", "check", "openai-compat")
        self.assertEqual(code, 0, out)
        self.assertIn("the credential is optional", out)
        self.assertNotIn("a credential is stored", out)

    def test_the_engines_named_in_the_settings_are_the_ones_checked(self):
        self.consent("clova", region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST)
        self.write_config(ASR_ENGINE="clova", ASR_CLOVA_INVOKE_URL=CLOVA_URL)
        code, out, _err = self.mcap("asr-engines", "check")
        self.assertEqual(code, 0, out)
        self.assertTrue(out.startswith("clova (cloud, kr)"))

    def test_live_sends_one_synthetic_tone_and_never_prints_the_answer_or_the_key(self):
        self.consent("clova", region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST)
        code, out, _err = self.mcap("asr-engines", "check", "clova", "--live", "--yes")
        self.assertEqual(code, 0, out)
        self.assertIn("one 1 s synthetic tone", out)
        self.assertIn("the text is not shown", out)
        self.assertIn("sent: 1 chunk request(s), 1.0 s of audio", out)
        call, = self.transport.calls
        self.assertEqual((call.method, call.target), ("POST", CLOVA_ID_PATH + "/recognizer/upload"))
        self.assertEqual(parse_multipart(call)["media"][0]["Content-Type"], "audio/wav")
        for needle in (CLOVA_KEY, CLOVA_ID_PATH, "액미"):
            self.assertNotIn(needle, out)


class ConsentTests(ProviderCliCase):
    def phrase(self, engine, host):
        return f"동의합니다 {engine}@{host}"

    def test_clova_consent_names_the_host_the_block_and_the_billing_and_binds_host_and_port(self):
        code, out, _err = self.mcap("asr-engines", "consent", "clova", stdin=self.tty(self.phrase("clova", CLOVA_HOST)))
        self.assertEqual(code, 0, out)
        for part in (f"{CLOVA_HOST}:443", "NAVER Cloud CLOVA Speech", "한 번에 최대 900초", "block.wav", "15초 단위로 올림", "청구는 사용자와 NAVER Cloud 사이의 일",
                     "boostings", "원격 참석자의 목소리", "하루 240분", "동의하려면 정확히 입력하세요: " + self.phrase("clova", CLOVA_HOST)):
            self.assertIn(part, out)
        self.assertNotIn("약 28초", out)                                                                # the generic chunk text does not apply
        self.assertNotIn(CLOVA_ID_PATH, out)                                                           # the user's domain is not printed
        entry, = self.entries()
        self.assertEqual((entry.engine, entry.kind, entry.host, entry.port, entry.region, entry.model, entry.protocol, entry.backend_kind, entry.ca_sha256),
                         ("clova", "cloud", CLOVA_HOST, 443, "", "clova-speech-long", "clova-speech-upload", "cloud", None))
        self.assertEqual(status.consent_state(self.cfg_loaded(), "clova", self.org, policy.load_consents(self.cfg.consent_path, machine_id=MACHINE, now=tca.NOW),
                                              tca.NOW)["state"], "ok")

    def cfg_loaded(self):
        return cli.load_config()

    def test_the_openai_style_consent_says_the_destination_was_chosen_by_the_user(self):
        code, out, _err = self.mcap("asr-engines", "consent", "openai-compat", stdin=self.tty("nothing"))
        for part in (f"{OAI_HOST}:443", "사용자가 직접 정한 서버", "ASR_OPENAI_COMPAT_URL", "어떤 벤더나 서버가 있는지 이 Mac은 알지도 확인하지도 못하고", "운영자의 손에 넘어갑니다",
                     "모델 이름(whisper-1)", "용어집을 보내지 않습니다", "한 번에 최대 720초", "청구는 사용자와 그 서버의 운영자 사이의 일",
                     "동의하려면 정확히 입력하세요: " + self.phrase("openai-compat", OAI_HOST)):
            self.assertIn(part, out)
        self.assertEqual(code, 1)                                                                       # the wrong sentence: nothing recorded
        self.assertEqual(self.entries(), ())

    def test_the_consent_names_the_block_length_the_provider_really_uses(self):
        # the setting is 900 (the default): CLOVA takes it, the OpenAI-style engine is held to 720 s (under the 25 MB upload limit)
        self.write_config(ASR_CLOUD_BLOCK_SECONDS="1800")
        self.assertIn("한 번에 최대 720초", self.mcap("asr-engines", "consent", "openai-compat", stdin=self.tty("nothing"))[1])
        self.assertIn("한 번에 최대 1800초", self.mcap("asr-engines", "consent", "clova", stdin=self.tty("nothing"))[1])

    def test_the_consent_follows_the_configured_block_length_and_model(self):
        self.write_config(ASR_CLOUD_BLOCK_SECONDS="300", ASR_OPENAI_COMPAT_MODEL="large-v3")
        out = self.mcap("asr-engines", "consent", "openai-compat", stdin=self.tty("nothing"))[1]
        self.assertIn("한 번에 최대 300초", out)
        self.assertIn("모델 이름(large-v3)", out)

    def test_the_typed_sentence_names_the_configured_host_so_another_host_cannot_be_consented_by_mistake(self):
        code, _out, err = self.mcap("asr-engines", "consent", "openai-compat", stdin=self.tty(self.phrase("openai-compat", "other.example.org")))
        self.assertEqual(code, 1)
        self.assertIn("the sentence did not match", err)
        code, out, _err = self.mcap("asr-engines", "consent", "openai-compat", stdin=self.tty(self.phrase("openai-compat", OAI_HOST)))
        self.assertEqual(code, 0, out)
        entry, = self.entries()
        self.assertEqual((entry.host, entry.protocol, entry.model, entry.region), (OAI_HOST, "openai-audio-transcriptions", "", ""))

    def test_a_consent_of_remote_and_azure_reads_exactly_as_before(self):
        out = self.mcap("asr-engines", "consent", "remote", stdin=self.tty("nothing"))[1]
        self.assertIn("한 번에 약 28초 이하", out)
        self.assertNotIn("block.wav", out)

    def test_consent_needs_a_configured_destination_and_a_terminal(self):
        self.write_config(ASR_CLOVA_INVOKE_URL="")
        code, _out, err = self.mcap("asr-engines", "consent", "clova", stdin=self.tty("x"))
        self.assertEqual(code, 2)
        self.assertIn("set ASR_CLOVA_INVOKE_URL (an https URL) in config.env first", err)
        code, _out, err = self.mcap("asr-engines", "consent", "openai-compat")
        self.assertEqual(code, 2)
        self.assertIn("typing a sentence in a terminal", err)


class SecretTests(ProviderCliCase):
    def test_status_and_forget_are_bound_to_the_host_of_the_provider(self):
        code, out, _err = self.mcap("asr-engines", "secret", "status", "clova")
        self.assertEqual(code, 0)
        self.assertIn("a credential is stored", out)
        self.assertIn("MeetingCapture ASR clova", out)
        self.assertNotIn(CLOVA_KEY, out)
        code, out, _err = self.mcap("asr-engines", "secret", "status", "openai-compat")
        self.assertEqual(code, 1)
        self.assertIn("no credential is stored (missing)", out)
        code, out, _err = self.mcap("asr-engines", "secret", "forget", "clova", "--yes")
        self.assertEqual(code, 0)
        self.assertEqual(self.mcap("asr-engines", "secret", "status", "clova")[0], 1)

    def test_set_refuses_without_a_terminal_and_names_the_setting_when_there_is_no_destination(self):
        code, _out, err = self.mcap("asr-engines", "secret", "set", "clova")
        self.assertEqual(code, 2)
        self.assertIn("must run in a terminal", err)
        self.write_config(ASR_CLOVA_INVOKE_URL="")
        code, _out, err = self.mcap("asr-engines", "secret", "set", "clova")
        self.assertEqual(code, 2)
        self.assertIn("set ASR_CLOVA_INVOKE_URL (an https URL) in config.env first", err)

    def test_revoke_withdraws_a_provider_consent_and_can_forget_its_key(self):
        self.consent("clova", region="", model="clova-speech-long", protocol="clova-speech-upload", host=CLOVA_HOST)
        code, out, _err = self.mcap("asr-engines", "revoke", "clova", "--forget-secret", "--yes")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.entries(), ())
        self.assertEqual(self.mcap("asr-engines", "secret", "status", "clova")[0], 1)


if __name__ == "__main__":
    unittest.main()
