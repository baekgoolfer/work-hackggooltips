"""asr_faster_whisper.py: the faster-whisper (CTranslate2) backend of the mcap-asr/1 server for a Linux host with an NVIDIA
GPU or a CPU. Everything is faked: a fake ``faster_whisper`` and a fake ``ctranslate2`` module are put into ``sys.modules`` (the real ones are
not installed here and are never imported), a fake ``huggingface_hub`` stands in for the hub, no socket is opened, no GPU is used, no model
exists, and the fake `security` of ``NoNetworkCase`` keeps the Keychain out of reach. Nothing in this file says the backend works on a real
GPU: only that it calls faster-whisper the way the design says and maps what comes back.

Covered: the module and the client import path never import faster_whisper (runtime and static), the registry lookup and why the client can
not name the backend, the server factory (options, defaults, MLX model refused), the lazy-import error text, model resolution (offline by
default, HF_HUB_OFFLINE honoured, a download only when allowed), device and compute-type planning and the CPU fallback, the exact decode
call (initial_prompt, language, vad_filter False, beam size, no hotwords), the mapping of segments, language ID, the prompt budget with the
model tokenizer, the prompt retry and the post-filters unchanged, release, the check/fetch commands, a request through the real server core,
requirements-server.txt, and the shell tests of the Linux installer.

Run: python -m unittest discover -s pipeline/tests -k asr_faster_whisper
"""
import ast
import collections
import contextlib
import io
import json
import logging
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from net_guard_support import NoNetworkCase  # noqa: E402

from mcap import asr, asr_engines, asr_faster_whisper as fwmod, asr_router, asr_server as S, policy, vad  # noqa: E402
from mcap.asr_engines import EngineCaps, EnginePolicyDenied, EngineUnavailable, ModelNotAvailable, WhisperEngine, engine_caps  # noqa: E402
from mcap.asr_faster_whisper import FasterWhisperEngine, RuntimePlan, plan_runtime  # noqa: E402
from mcap.config import Config  # noqa: E402
from mcap.vocab import Vocab, parse_vocab_text  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
PIPELINE = REPO / "pipeline"
SR = 16000
GPU_TYPES = {"float16", "int8_float16", "int8", "float32", "int8_float32"}
CPU_TYPES = {"int8", "int8_float32", "float32"}
logging.getLogger("mcap").addHandler(logging.NullHandler())


# ---------------------------------------------------------------------------------------------- fakes
def fseg(start, end, text, lp=-0.3, ns=0.02, cr=1.1, **extra):
    """A faster-whisper ``Segment`` (a namedtuple / dataclass there, a namespace here). ``temperature`` only when given (older versions
    had no such field)."""
    return types.SimpleNamespace(id=1, seek=0, start=start, end=end, text=text, tokens=[1, 2, 3], avg_logprob=lp,
                                 compression_ratio=cr, no_speech_prob=ns, words=None, **extra)


class FakeHfTokenizer:
    """One token per whitespace-separated word; records how it was called."""

    def __init__(self):
        self.calls = []

    def encode(self, text, add_special_tokens=True):
        self.calls.append((text, add_special_tokens))
        return types.SimpleNamespace(ids=list(range(len(text.split()))))


class FakeStack:
    """A fake ``faster_whisper`` + ``ctranslate2`` pair. ``constructed`` lists every ``WhisperModel(...)`` call (path, kwargs), ``models`` the
    instances that exist, ``unloaded`` the ones whose ``model.unload_model()`` was called. ``create_errors[device]`` makes the constructor
    fail, ``first_call_errors[device]`` makes the first ``transcribe`` of a model fail at once, inside the call (the feature extraction of
    the real library), ``lazy_first_call_errors[device]`` makes it fail while the returned generator is consumed (the cuDNN case of the real
    library: ``transcribe()`` returns, the encoder and decoder run when the segments are iterated; the model loads, the first decode does
    not), ``script`` is a list of results (a list of segments, or an exception) for the next ``transcribe`` calls, ``lid`` the answer of
    ``detect_language``. Every model counts in ``exhausted`` the generators that were consumed to the end."""

    def __init__(self, cuda=1, gpu_types=GPU_TYPES, cpu_types=CPU_TYPES):
        self.cuda, self.types = cuda, {"cuda": gpu_types, "cpu": cpu_types}
        self.constructed, self.models, self.unloaded = [], [], []
        self.create_errors, self.first_call_errors, self.lazy_first_call_errors, self.script = {}, {}, {}, []
        self.default_segments = [fseg(0.2, 2.0, " hello world", temperature=0.0)]
        self.lid = ("ko", 0.9, [("ko", 0.9), ("en", 0.06), ("ja", 0.04)])
        stack = self

        class WhisperModel:
            def __init__(self, path, **kwargs):
                stack.constructed.append((path, dict(kwargs)))
                error = stack.create_errors.get(kwargs.get("device"))
                if error is not None:
                    raise error
                self.path, self.kwargs, self.device = path, kwargs, kwargs.get("device")
                self.hf_tokenizer = FakeHfTokenizer()
                self.model = types.SimpleNamespace(unload_model=lambda: stack.unloaded.append(self))
                self.transcribe_calls, self.detect_calls = [], []
                self.exhausted = 0
                stack.models.append(self)

            def transcribe(self, audio, **kwargs):
                first = not self.transcribe_calls
                self.transcribe_calls.append((audio, kwargs))
                error = stack.first_call_errors.get(self.device) if first else None
                if error is not None:
                    raise error
                lazy = stack.lazy_first_call_errors.get(self.device) if first else None
                items = stack.script.pop(0) if stack.script else stack.default_segments
                if isinstance(items, BaseException):
                    raise items
                model = self

                def generate():
                    if lazy is not None:                                  # the real library: nothing is decoded before the first next()
                        raise lazy
                    for item in items:
                        if isinstance(item, BaseException):
                            raise item
                        yield item
                    model.exhausted += 1
                return generate(), types.SimpleNamespace(language=kwargs.get("language"), language_probability=1.0)

            def detect_language(self, audio, **kwargs):
                self.detect_calls.append(audio)
                return stack.lid

        self.fw = types.ModuleType("faster_whisper")
        self.fw.WhisperModel = WhisperModel
        self.fw.__version__ = "1.1.1-fake"
        self.ct2 = types.ModuleType("ctranslate2")
        self.ct2.get_cuda_device_count = lambda: stack.cuda
        self.ct2.get_supported_compute_types = lambda device: set(stack.types[device])
        self.ct2.__version__ = "4.5.0-fake"

    @property
    def modules(self):
        return {"faster_whisper": self.fw, "ctranslate2": self.ct2}

    @property
    def model(self):
        return self.models[-1]


class FwCase(NoNetworkCase):
    """A ``NoNetworkCase`` with a fake stack in ``sys.modules``, an unset HF_HUB_OFFLINE and a complete fake model directory."""

    def setUp(self):
        super().setUp()
        self.stack = FakeStack()
        self.use(self.stack)
        env = mock.patch.dict(os.environ)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("HF_HUB_OFFLINE", None)
        self.model_dir = self.make_model_dir(self.root / "ct2-model")

    def use(self, stack):
        patcher = mock.patch.dict(sys.modules, stack.modules)
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def make_model_dir(path, files=("model.bin", "config.json", "tokenizer.json", "vocabulary.json")):
        path.mkdir(parents=True, exist_ok=True)
        for name in files:
            (path / name).write_text("x")
        return path

    def engine(self, **kw):
        kw.setdefault("allow_download", False)
        kw.setdefault("device", "cuda")
        return FasterWhisperEngine(str(self.model_dir), **kw)

    def loaded(self, **kw):
        engine = self.engine(**kw)
        engine.load()
        self.addCleanup(engine.release)
        return engine


# ---------------------------------------------------------------------------------------------- the client never imports it
CLIENT_MODULES = ("mcap.asr", "mcap.asr_engines", "mcap.asr_router", "mcap.asr_http", "mcap.pipeline", "mcap.cli", "mcap.policy",
                  "mcap.config", "mcap.transcript")


def run_python(code, home):
    """``python -c code`` in a clean environment whose HOME (and the log and config hooks) is a temp directory: whatever the imports do, they
    can not reach the real support or log directory."""
    full = {"PATH": os.environ.get("PATH", ""), "PYTHONPATH": str(PIPELINE), "PYTHONDONTWRITEBYTECODE": "1", "HOME": str(home),
            "MCAP_LOG_DIR": str(Path(home) / "logs"), "MCAP_CONFIG": str(Path(home) / "none.env")}
    return subprocess.run([sys.executable, "-c", code], env=full, capture_output=True, text=True, timeout=120, cwd=str(home))


class ClientNeverImportsTests(unittest.TestCase):
    def setUp(self):
        self._home = tempfile.TemporaryDirectory(prefix="mcap-fw-home-")
        self.addCleanup(self._home.cleanup)
        self.home = Path(self._home.name)

    def test_importing_the_module_and_the_client_path_imports_neither_package_nor_the_module(self):
        probe = ("import sys, importlib\n"
                 "for name in %r:\n"
                 "    importlib.import_module(name)\n"
                 "bad = sorted(m for m in ('faster_whisper', 'ctranslate2', 'mcap.asr_faster_whisper') if m in sys.modules)\n"
                 "print('LOADED', bad)\n") % (CLIENT_MODULES,)
        result = run_python(probe, self.home)
        self.assertEqual(result.returncode, 0, result.stderr[-800:])
        self.assertIn("LOADED []", result.stdout)
        self.assertEqual(os.listdir(self.home), [])                              # importing the client creates nothing

    def test_importing_the_backend_module_does_not_import_the_packages(self):
        result = run_python("import sys, mcap.asr_faster_whisper\nprint('LOADED', sorted(m for m in ('faster_whisper', 'ctranslate2') if m in sys.modules))\n", self.home)
        self.assertEqual(result.returncode, 0, result.stderr[-800:])
        self.assertIn("LOADED []", result.stdout)

    def test_no_client_module_imports_it(self):
        """Static: no module of the package imports faster_whisper, ctranslate2 or asr_faster_whisper except asr_faster_whisper itself,
        and asr_engines only names it as a string of SERVER_BACKENDS."""
        forbidden = ("faster_whisper", "ctranslate2", "asr_faster_whisper")
        offenders = []
        for path in sorted((PIPELINE / "mcap").glob("*.py")):
            if path.name == "asr_faster_whisper.py":
                continue
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                names = []
                if isinstance(node, ast.Import):
                    names = [a.name for a in node.names]
                elif isinstance(node, ast.ImportFrom):
                    names = [(node.module or "")] + [a.name for a in node.names]
                if any(part in forbidden for name in names for part in name.split(".")):
                    offenders.append(f"{path.name}:{node.lineno}")
        self.assertEqual(offenders, [])

    def test_the_backend_imports_the_packages_only_inside_functions(self):
        tree = ast.parse((PIPELINE / "mcap" / "asr_faster_whisper.py").read_text(encoding="utf-8"))
        for node in tree.body:
            if isinstance(node, ast.Import):
                self.assertFalse({a.name.split(".")[0] for a in node.names} & {"faster_whisper", "ctranslate2"})
            if isinstance(node, ast.ImportFrom):
                self.assertNotIn((node.module or "").split(".")[0], {"faster_whisper", "ctranslate2"})


# ---------------------------------------------------------------------------------------------- registry
class RegistryTests(NoNetworkCase):
    def test_engine_class_finds_the_backend(self):
        self.assertIs(asr_engines.engine_class("faster-whisper"), FasterWhisperEngine)
        self.assertEqual(asr_engines.SERVER_BACKENDS, {"faster-whisper": "mcap.asr_faster_whisper:FasterWhisperEngine"})

    def test_it_is_a_server_backend_not_a_client_engine(self):
        self.assertNotIn("faster-whisper", asr_engines.REGISTRY)
        self.assertNotIn("faster-whisper", policy.ENGINE_META)
        self.assertNotIn("faster-whisper", policy.ASR_ENGINE_CHOICES)
        self.assertNotIn("faster-whisper", policy.ASR_FALLBACK_CHOICES)
        self.assertEqual(set(policy.ENGINE_META), set(asr_engines.REGISTRY))             # the pinned relation is untouched

    def test_a_policy_decision_or_router_can_not_build_it(self):
        with self.assertRaises(EnginePolicyDenied):
            asr_router.build_member(None, None, None, "faster-whisper")

    def test_the_unknown_engine_message_lists_it(self):
        with self.assertRaisesRegex(EngineUnavailable, r"unknown ASR engine 'nope' \(known: .*faster-whisper.*whisper"):
            asr_engines.engine_class("nope")

    def test_a_broken_server_backend_entry_is_engine_unavailable(self):
        with mock.patch.dict(asr_engines.SERVER_BACKENDS, {"x-missing": "mcap.no_such_module_w5d:Nope"}):
            with self.assertRaisesRegex(EngineUnavailable, "is not available"):
                asr_engines.engine_class("x-missing")

    def test_the_seam_attributes(self):
        engine = FasterWhisperEngine("large-v3", allow_download=False)
        self.assertEqual((engine.name, engine.engine_id, engine.kind, engine.residency), ("faster-whisper", "faster-whisper", "local", "device"))
        self.assertEqual(engine_caps(engine), EngineCaps(kind="local", uses_prompt=True, supports_lid=True, timing="segment",
                                                         confidence="logprob", max_chunk_s=asr_engines.MAX_CHUNK_S, residency="device"))
        self.assertEqual(engine.prompt_frames, WhisperEngine.prompt_frames)
        info = engine.describe()
        self.assertEqual((info["engine"], info["model"], info["kind"]), ("faster-whisper", "large-v3", "local"))
        self.assertEqual((engine.usage(), engine.provenance(), engine.prompt_text_seen(), engine.progress_tag()), ({}, None, None, ""))


# ---------------------------------------------------------------------------------------------- the server factory
class ServerFactoryTests(NoNetworkCase):
    def cfg(self, **over):
        return S.config_from_dict({"secrets_dir": str(self.root), "log_dir": str(self.root), "backend": "faster-whisper", **over})

    def build(self, **over):
        with mock.patch.dict(sys.modules, {"faster_whisper": None, "ctranslate2": None}):       # constructing must not import them
            return S.default_backend_factory(self.cfg(**over))

    def test_the_default_model_is_a_ctranslate2_model_not_the_mlx_default(self):
        engine = self.build()
        self.assertIsInstance(engine, FasterWhisperEngine)
        self.assertEqual((engine.model, engine.allow_download), ("large-v3", False))
        self.assertNotEqual(engine.model, S.DEFAULT_MODEL)
        self.assertIsNone(engine.path)

    def test_options_and_model_reach_the_engine(self):
        engine = self.build(model="/srv/models/large-v3-ct2", backend_options={"device": "cpu", "compute_type": "int8", "beam_size": 2,
                                                                               "cpu_threads": 8, "num_workers": 2, "warmup": False})
        self.assertEqual((engine.model, engine.device, engine.compute_type, engine.beam_size, engine.cpu_threads, engine.num_workers, engine.warmup),
                         ("/srv/models/large-v3-ct2", "cpu", "int8", 2, 8, 2, False))

    def test_the_server_never_downloads_whatever_the_options_say(self):
        self.assertFalse(self.build().allow_download)
        with self.assertRaisesRegex(ValueError, "never downloads"):
            self.build(backend_options={"allow_download": True})

    def test_an_unknown_option_or_a_bad_value_refuses_to_start(self):
        for options, pattern in (({"devise": "cpu"}, "unknown backend_options key 'devise'"), ({"device": "tpu"}, "device must be"),
                                 ({"compute_type": "float32"}, "compute_type must be"), ({"beam_size": 0}, "beam_size"),
                                 ({"beam_size": True}, "beam_size"), ({"cpu_threads": -1}, "cpu_threads"), ({"num_workers": 99}, "num_workers"),
                                 ({"device_index": "0"}, "device_index"), ({"warmup": 1}, "warmup")):
            with self.subTest(options), self.assertRaisesRegex(ValueError, pattern):
                self.build(backend_options=options)

    def test_an_mlx_model_is_refused_with_the_reason(self):
        for model in ("mlx-community/whisper-large-v3-mlx", "someone/whisper-turbo-mlx"):
            with self.subTest(model), self.assertRaisesRegex(ValueError, "MLX model"):
                self.build(model=model)

    def test_the_strict_config_accepts_the_backend_id(self):
        cfg = self.cfg(backend_options={"device": "auto"})
        self.assertEqual((cfg.backend, dict(cfg.backend_options)), ("faster-whisper", {"device": "auto"}))

    def test_a_missing_package_is_a_startup_refusal_with_the_install_hint(self):
        """``serve`` turns what the factory or ``start()`` raises into ``StartupRefused``; the text must tell the operator what to install."""
        engine = self.build()
        with mock.patch.dict(sys.modules, {"faster_whisper": None}), self.assertRaises(EngineUnavailable) as caught:
            S.ServerState(self.cfg(), engine).start()
        self.assertIn("requirements-server.txt", str(caught.exception)[:200])


# ---------------------------------------------------------------------------------------------- lazy import
class LazyImportTests(FwCase):
    def assert_install_hint(self, text):
        for needle in ("faster-whisper cannot be imported", "pip install -r pipeline/requirements-server.txt", "SERVER venv", "docs/ASR_SERVER_LINUX.md"):
            self.assertIn(needle, text)

    def test_constructing_imports_nothing(self):
        with mock.patch.dict(sys.modules, {"faster_whisper": None}):
            FasterWhisperEngine("large-v3", allow_download=False)              # would raise ImportError if it imported

    def test_load_without_the_package_says_what_to_install(self):
        with mock.patch.dict(sys.modules, {"faster_whisper": None}), self.assertRaises(EngineUnavailable) as caught:
            self.engine().load()
        self.assert_install_hint(str(caught.exception))
        self.assertTrue(str(caught.exception).startswith("faster-whisper cannot be imported"))     # the server clips messages to 200 chars

    def test_a_missing_shared_library_is_the_same_error(self):
        class Raising:
            def find_spec(self, name, path=None, target=None):
                if name == "faster_whisper":
                    raise OSError("libcudart.so.12: cannot open shared object file")

        finder = Raising()
        sys.meta_path.insert(0, finder)
        self.addCleanup(sys.meta_path.remove, finder)
        with mock.patch.dict(sys.modules):
            sys.modules.pop("faster_whisper")
            with self.assertRaises(EngineUnavailable) as caught:
                self.engine().load()
        self.assert_install_hint(str(caught.exception))
        self.assertIn("libcudart.so.12", str(caught.exception))

    def test_every_entry_point_raises_the_same_actionable_error(self):
        engine = self.engine()
        with mock.patch.dict(sys.modules, {"faster_whisper": None}):
            for call in (lambda: engine.tokenizer, lambda: engine.detect_languages([np.zeros(SR, np.float32)]),
                         lambda: engine.transcribe_chunk(np.zeros(SR, np.float32), "ko", None)):
                with self.subTest(call), self.assertRaises(EngineUnavailable):
                    call()

    def test_release_without_a_load_is_harmless(self):
        FasterWhisperEngine("large-v3", allow_download=False).release()


# ---------------------------------------------------------------------------------------------- the model: offline by default
class FakeHub:
    """A fake ``huggingface_hub``: ``cached`` is what the local-only lookup finds (a path or None), ``downloaded`` what a download returns."""

    def __init__(self, cached=None, downloaded=None):
        self.cached, self.downloaded, self.calls = cached, downloaded, []
        hub = self
        self.module = types.ModuleType("huggingface_hub")

        def snapshot_download(repo, revision=None, local_files_only=False, **kw):
            hub.calls.append((repo, bool(local_files_only)))
            if local_files_only:
                if hub.cached is None:
                    raise FileNotFoundError("not in the cache")
                return hub.cached
            return hub.downloaded

        self.module.snapshot_download = snapshot_download


class ModelResolutionTests(FwCase):
    def test_a_complete_directory_is_used_as_it_is(self):
        engine = self.engine()
        self.assertEqual(engine.resolve_path(), str(self.model_dir))
        self.assertEqual(engine.path, str(self.model_dir))

    def test_an_incomplete_directory_names_what_is_missing(self):
        for missing in ("model.bin", "tokenizer.json", "config.json"):
            broken = self.make_model_dir(self.root / f"broken-{missing}", files=tuple(n for n in ("model.bin", "config.json", "tokenizer.json",
                                                                                                  "vocabulary.json") if n != missing))
            with self.subTest(missing), self.assertRaisesRegex(ModelNotAvailable, "not a complete CTranslate2 Whisper model"):
                FasterWhisperEngine(str(broken), allow_download=False).resolve_path()
        no_vocab = self.make_model_dir(self.root / "no-vocab", files=("model.bin", "config.json", "tokenizer.json"))
        with self.assertRaises(ModelNotAvailable):
            FasterWhisperEngine(str(no_vocab), allow_download=False).resolve_path()
        (no_vocab / "vocabulary.txt").write_text("x")                           # the older spelling is as good
        self.assertEqual(FasterWhisperEngine(str(no_vocab), allow_download=False).resolve_path(), str(no_vocab))

    def test_a_directory_that_is_not_there_is_not_taken_for_a_repo(self):
        for model in ("/srv/models/none-there", "./relative/none", "~/none-there"):
            with self.subTest(model), self.assertRaisesRegex(ModelNotAvailable, "does not exist"):
                FasterWhisperEngine(model, allow_download=False).resolve_path()

    def test_a_short_name_maps_to_its_repository_and_an_unknown_one_is_refused(self):
        seen = []

        def fake(repo, *, allow_download, check):
            seen.append((repo, allow_download, check))
            return str(self.model_dir)

        with mock.patch.object(fwmod, "resolve_model_path", fake):
            for name, repo in (("large-v3", "Systran/faster-whisper-large-v3"), ("distil-large-v3", "Systran/faster-distil-whisper-large-v3"),
                               ("some-owner/some-ct2-model", "some-owner/some-ct2-model")):
                FasterWhisperEngine(name, allow_download=False).resolve_path()
                self.assertEqual(seen[-1][0], repo)
        self.assertTrue(all(row[1] is False and row[2] is fwmod.ct2_files_present for row in seen))
        with self.assertRaisesRegex(ModelNotAvailable, "unknown faster-whisper model name 'large-v9'"):
            FasterWhisperEngine("large-v9", allow_download=False).resolve_path()
        with self.assertRaisesRegex(ModelNotAvailable, "unknown faster-whisper model name 'turbo'"):         # no short name for the turbo model
            FasterWhisperEngine("turbo", allow_download=False).resolve_path()

    def test_the_cache_check_requires_the_tokenizer_file(self):
        """A snapshot without tokenizer.json would make faster-whisper fetch a tokenizer from the hub: it counts as incomplete."""
        complete = self.make_model_dir(self.root / "snap-ok")
        partial = self.make_model_dir(self.root / "snap-partial", files=("model.bin", "config.json", "vocabulary.json"))
        self.assertTrue(fwmod.ct2_files_present(complete))
        self.assertFalse(fwmod.ct2_files_present(partial))

    def test_offline_by_default_nothing_is_downloaded(self):
        hub = FakeHub(cached=None, downloaded=str(self.model_dir))
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}), self.assertRaisesRegex(ModelNotAvailable, "downloads are disabled"):
            FasterWhisperEngine("large-v3", allow_download=False).resolve_path()
        self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True)])

    def test_a_cached_model_is_used_without_a_download(self):
        hub = FakeHub(cached=str(self.model_dir))
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
            self.assertEqual(FasterWhisperEngine("large-v3", allow_download=True).resolve_path(), str(self.model_dir))
        self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True)])

    def test_a_download_happens_only_when_allowed_and_is_logged(self):
        hub = FakeHub(cached=None, downloaded=str(self.model_dir))
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}), self.assertLogs("mcap.asr", "WARNING") as logs:
            self.assertEqual(FasterWhisperEngine("large-v3", allow_download=True).resolve_path(), str(self.model_dir))
        self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True), ("Systran/faster-whisper-large-v3", False)])
        self.assertTrue(any("DOWNLOADING ASR model Systran/faster-whisper-large-v3" in line for line in logs.output))

    def test_hf_hub_offline_wins_over_allow_download(self):
        for value in ("1", "true", "YES", "on"):
            hub = FakeHub(cached=None, downloaded=str(self.model_dir))
            with self.subTest(value), mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": value}), mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
                with self.assertLogs("mcap.asr", "WARNING") as logs, self.assertRaisesRegex(ModelNotAvailable, "downloads are disabled"):
                    FasterWhisperEngine("large-v3", allow_download=True).resolve_path()
            self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True)])
            self.assertTrue(any("HF_HUB_OFFLINE" in line for line in logs.output))
        self.assertFalse(fwmod.hf_offline())
        for value in ("0", "false", ""):
            with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": value}):
                self.assertFalse(fwmod.hf_offline(), value)

    def test_load_passes_the_resolved_directory_and_never_lets_faster_whisper_go_to_the_hub(self):
        engine = self.loaded()
        path, kwargs = self.stack.constructed[0]
        self.assertEqual(path, str(self.model_dir))
        self.assertIs(kwargs["local_files_only"], True)


# ---------------------------------------------------------------------------------------------- device and compute type
class PlanRuntimeTests(unittest.TestCase):
    @staticmethod
    def types_of(gpu=GPU_TYPES, cpu=CPU_TYPES):
        return lambda device: set(gpu if device == "cuda" else cpu)

    def plan(self, device, compute_type, cuda=1, supported=None):
        return plan_runtime(device, compute_type, cuda_count=cuda, supported=supported or self.types_of())

    def test_auto_takes_the_gpu_when_there_is_one(self):
        self.assertEqual(self.plan("auto", "float16"), RuntimePlan("cuda", "float16", ()))
        self.assertEqual(self.plan("auto", "int8_float16"), RuntimePlan("cuda", "int8_float16", ()))

    def test_auto_without_a_gpu_is_the_cpu_with_int8_and_says_so(self):
        plan = self.plan("auto", "float16", cuda=0)
        self.assertEqual((plan.device, plan.compute_type), ("cpu", "int8"))
        self.assertEqual(len(plan.notes), 2)
        self.assertIn("no CUDA device", plan.notes[0])
        self.assertIn("compute_type float16 is not available on cpu: using int8", plan.notes[1])

    def test_the_two_float16_types_become_int8_on_the_cpu(self):
        for requested in ("float16", "int8_float16"):
            self.assertEqual(self.plan("cpu", requested)[:2], ("cpu", "int8"), requested)
        self.assertEqual(self.plan("cpu", "int8"), RuntimePlan("cpu", "int8", ()))

    def test_cpu_is_cpu_even_when_a_gpu_exists(self):
        self.assertEqual(self.plan("cpu", "int8", cuda=2).device, "cpu")

    def test_cuda_without_a_device_never_falls_back(self):
        with self.assertRaisesRegex(EngineUnavailable, "device 'cuda' was requested but CTranslate2 sees no CUDA device"):
            self.plan("cuda", "float16", cuda=0)

    def test_a_gpu_without_float16_walks_down_the_chain(self):
        old_gpu = {"int8", "float32"}
        plan = self.plan("cuda", "float16", supported=self.types_of(gpu=old_gpu))
        self.assertEqual((plan.device, plan.compute_type), ("cuda", "int8"))
        self.assertIn("compute_type float16 is not available on cuda: using int8", plan.notes[0])

    def test_nothing_usable_is_an_error_that_lists_what_is_supported(self):
        with self.assertRaisesRegex(EngineUnavailable, r"not supported on cuda: CTranslate2 reports float16"):
            self.plan("cuda", "int8", supported=self.types_of(gpu={"float16"}))

    def test_without_knowledge_of_the_supported_types_the_cpu_keeps_int8_only(self):
        unknown = lambda device: None                        # noqa: E731
        self.assertEqual(self.plan("cpu", "float16", supported=unknown)[:2], ("cpu", "int8"))
        self.assertEqual(self.plan("cpu", "int8_float16", supported=unknown)[:2], ("cpu", "int8"))
        self.assertEqual(self.plan("cuda", "int8_float16", supported=unknown)[:2], ("cuda", "int8_float16"))


class LoadRuntimeTests(FwCase):
    def test_gpu_load_arguments_and_a_silent_warm_up(self):
        engine = self.loaded(device="cuda", device_index=1, compute_type="int8_float16", cpu_threads=4, num_workers=2)
        self.assertEqual(self.stack.constructed, [(str(self.model_dir), dict(device="cuda", compute_type="int8_float16", cpu_threads=4,
                                                                             num_workers=2, local_files_only=True, device_index=1))])
        audio, kwargs = self.stack.model.transcribe_calls[0]                    # the warm-up: one second of silence, nothing else
        self.assertEqual((audio.shape, audio.dtype, float(np.abs(audio).max())), ((SR,), np.float32, 0.0))
        self.assertEqual((kwargs["language"], kwargs["beam_size"], kwargs["vad_filter"]), ("en", 1, False))
        self.assertEqual((engine.active_device, engine.active_compute_type), ("cuda", "int8_float16"))
        self.assertEqual(engine.runtime()["device"], "cuda")

    def test_device_index_is_for_the_gpu_only(self):
        self.stack.cuda = 0
        self.loaded(device="cpu", device_index=3)
        self.assertNotIn("device_index", self.stack.constructed[0][1])

    def test_cpu_fallback_of_auto_without_a_gpu_is_logged(self):
        self.stack.cuda = 0
        with self.assertLogs("mcap.asr", "WARNING") as logs:
            engine = self.loaded(device="auto", compute_type="float16")
        self.assertEqual((engine.active_device, engine.active_compute_type), ("cpu", "int8"))
        self.assertEqual(self.stack.constructed[0][1]["compute_type"], "int8")
        self.assertTrue(any("no CUDA device" in line for line in logs.output))

    def test_load_is_idempotent_and_the_warm_up_can_be_switched_off(self):
        engine = self.loaded(warmup=False)
        self.assertEqual(self.stack.model.transcribe_calls, [])
        engine.load()
        engine.load()
        self.assertEqual(len(self.stack.constructed), 1)

    def test_auto_falls_back_to_the_cpu_when_the_gpu_cannot_decode(self):
        """The cuDNN case: the model loads on the GPU and the first decode fails. The half-started model is freed."""
        self.stack.first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        with self.assertLogs("mcap.asr", "WARNING") as logs:
            engine = self.loaded(device="auto")
        self.assertEqual([k["device"] for _p, k in self.stack.constructed], ["cuda", "cpu"])
        self.assertEqual((engine.active_device, engine.active_compute_type), ("cpu", "int8"))
        self.assertEqual(len(self.stack.unloaded), 1)
        self.assertEqual(self.stack.unloaded[0].device, "cuda")
        self.assertTrue(any("falling back to the CPU" in line and "RuntimeError" in line for line in logs.output))

    def test_the_warm_up_consumes_the_lazy_generator(self):
        """faster-whisper decodes while the generator is iterated: a warm-up that only called transcribe() would test nothing."""
        self.loaded(device="cuda")
        self.assertEqual((len(self.stack.models), self.stack.model.exhausted), (1, 1))

    def test_auto_falls_back_to_the_cpu_when_the_gpu_fails_inside_the_lazy_generator(self):
        """The cuDNN case as the real library shows it: transcribe() returns, the error comes out of the first iteration."""
        self.stack.lazy_first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        with self.assertLogs("mcap.asr", "WARNING") as logs:
            engine = self.loaded(device="auto")
        self.assertEqual([k["device"] for _p, k in self.stack.constructed], ["cuda", "cpu"])
        self.assertEqual((engine.active_device, engine.active_compute_type), ("cpu", "int8"))
        self.assertEqual([m.device for m in self.stack.unloaded], ["cuda"])                   # the half-started model is freed
        self.assertEqual([(m.device, m.exhausted) for m in self.stack.models], [("cuda", 0), ("cpu", 1)])
        self.assertTrue(any("falling back to the CPU" in line and "libcudnn_ops" in line for line in logs.output))

    def test_an_explicit_cuda_never_falls_back_when_it_fails_inside_the_lazy_generator(self):
        self.stack.lazy_first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        engine = self.engine(device="cuda")
        with self.assertRaisesRegex(EngineUnavailable, r"could not start on cuda \(float16\): RuntimeError: Could not load library libcudnn"):
            engine.load()
        self.assertEqual([k["device"] for _p, k in self.stack.constructed], ["cuda"])
        self.assertIsNone(engine._model)
        self.assertEqual(len(self.stack.unloaded), 1)

    def test_auto_falls_back_when_the_gpu_model_cannot_even_be_created(self):
        self.stack.create_errors["cuda"] = RuntimeError("CUDA failed with error out of memory")
        with self.assertLogs("mcap.asr", "WARNING"):
            engine = self.loaded(device="auto")
        self.assertEqual(engine.active_device, "cpu")

    def test_an_explicit_cuda_never_falls_back(self):
        self.stack.first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        engine = self.engine(device="cuda")
        with self.assertRaisesRegex(EngineUnavailable, r"could not start on cuda \(float16\): RuntimeError: Could not load library libcudnn"):
            engine.load()
        self.assertEqual([k["device"] for _p, k in self.stack.constructed], ["cuda"])
        self.assertIsNone(engine._model)
        self.assertEqual(len(self.stack.unloaded), 1)

    def test_an_explicit_cpu_failure_is_an_error(self):
        self.stack.create_errors["cpu"] = RuntimeError("bad model.bin")
        with self.assertRaisesRegex(EngineUnavailable, "could not start on cpu"):
            self.engine(device="cpu").load()

    def test_auto_that_fails_everywhere_says_so(self):
        self.stack.create_errors["cuda"] = RuntimeError("no")
        self.stack.create_errors["cpu"] = RuntimeError("bad model.bin")
        with self.assertLogs("mcap.asr", "WARNING"), self.assertRaisesRegex(EngineUnavailable, "could not start on cuda or on the cpu"):
            self.engine(device="auto").load()

    def test_explicit_cuda_without_a_device_fails_before_a_model_is_built(self):
        self.stack.cuda = 0
        with self.assertRaisesRegex(EngineUnavailable, "sees no CUDA device"):
            self.engine(device="cuda").load()
        self.assertEqual(self.stack.constructed, [])

    def test_a_missing_ctranslate2_module_means_no_gpu(self):
        with mock.patch.dict(sys.modules, {"ctranslate2": None}):
            engine = self.loaded(device="auto", warmup=False)
        self.assertEqual((engine.active_device, engine.active_compute_type), ("cpu", "int8"))


# ---------------------------------------------------------------------------------------------- decoding
class DecodeTests(FwCase):
    def audio(self, seconds=2.0):
        return np.full(int(seconds * SR), 0.1, dtype=np.float64)

    def last_call(self):
        return self.stack.model.transcribe_calls[-1]

    def test_the_exact_decode_call(self):
        engine = self.loaded()
        engine.transcribe_chunk(self.audio(), "ko", "다음은 용어: Acme, FDA")
        audio, kwargs = self.last_call()
        self.assertEqual((audio.dtype, audio.flags["C_CONTIGUOUS"], len(audio)), (np.float32, True, 2 * SR))
        self.assertEqual(kwargs, dict(language="ko", task="transcribe", beam_size=5, initial_prompt="다음은 용어: Acme, FDA", vad_filter=False,
                                      condition_on_previous_text=False, temperature=(0.0, 0.2, 0.4, 0.6), compression_ratio_threshold=2.4,
                                      log_prob_threshold=-1.0, no_speech_threshold=0.6, word_timestamps=False))

    def test_hotwords_and_the_faster_whisper_vad_are_never_used(self):
        engine = self.loaded()
        engine.transcribe_chunk(self.audio(), "en", "A medical AI meeting. Terms: FDA")
        _audio, kwargs = self.last_call()
        for forbidden in ("hotwords", "vad_parameters", "clip_timestamps", "prefix", "language_detection_threshold", "multilingual"):
            self.assertNotIn(forbidden, kwargs)
        self.assertIs(kwargs["vad_filter"], False)
        self.assertNotIn("hotwords", fwmod.FasterWhisperEngine.DECODE_KW)
        self.assertIs(kwargs["word_timestamps"], False)

    def test_no_prompt_means_initial_prompt_none(self):
        engine = self.loaded()
        for prompt in (None, ""):
            engine.transcribe_chunk(self.audio(), "en", prompt)
            self.assertIsNone(self.last_call()[1]["initial_prompt"])

    def test_the_beam_size_is_configurable(self):
        engine = self.loaded(beam_size=1)
        engine.transcribe_chunk(self.audio(), "en", None)
        self.assertEqual(self.last_call()[1]["beam_size"], 1)

    def test_segments_are_mapped_with_their_log_prob_fields(self):
        self.stack.default_segments = [fseg(0.25, 2.5, " 안녕하세요 Acme", lp=-0.2, ns=0.01, cr=1.3, temperature=0.2),
                                       fseg(2.5, 4.0, " FDA 510(k)", lp=-0.6, ns=0.05, cr=1.5, temperature=0.0)]
        engine = self.loaded()
        result = engine.transcribe_chunk(self.audio(4.5), "ko", None)
        self.assertEqual(result["segments"], [
            {"start": 0.25, "end": 2.5, "text": "안녕하세요 Acme", "avg_logprob": -0.2, "no_speech_prob": 0.01, "compression_ratio": 1.3, "temperature": 0.2},
            {"start": 2.5, "end": 4.0, "text": "FDA 510(k)", "avg_logprob": -0.6, "no_speech_prob": 0.05, "compression_ratio": 1.5, "temperature": 0.0}])
        self.assertEqual(result["text"], "안녕하세요 Acme FDA 510(k)")
        self.assertEqual(result["language"], "ko")
        self.assertAlmostEqual(result["avg_logprob"], -0.4)
        for seg in result["segments"]:
            self.assertTrue(all(isinstance(v, float) for k, v in seg.items() if k != "text"))
        json.dumps(result, allow_nan=False)

    def test_a_segment_without_a_temperature_field_gets_zero(self):
        self.stack.default_segments = [fseg(0.0, 1.0, " hi")]
        result = self.loaded().transcribe_chunk(self.audio(), "en", None)
        self.assertEqual(result["segments"][0]["temperature"], 0.0)

    def test_non_finite_and_missing_confidence_become_none(self):
        self.stack.default_segments = [fseg(0.0, 1.0, " a", lp=float("-inf"), ns=float("nan"), cr=None),
                                       fseg(1.0, 2.0, " b", lp=None, ns=None, cr=1.0, temperature=float("nan"))]
        result = self.loaded().transcribe_chunk(self.audio(), "en", None)
        for seg in result["segments"]:
            self.assertIsNone(seg["avg_logprob"])
            self.assertIsNone(seg["no_speech_prob"])
        self.assertIsNone(result["segments"][0]["compression_ratio"])
        self.assertEqual(result["segments"][1]["temperature"], 0.0)
        self.assertIsNone(result["avg_logprob"])
        json.dumps(result, allow_nan=False)

    def test_no_speech_is_an_empty_answer(self):
        self.stack.default_segments = []
        result = self.loaded().transcribe_chunk(self.audio(), "en", None)
        self.assertEqual(result, {"text": "", "segments": [], "language": "en", "avg_logprob": None})

    def test_the_lazy_generator_is_consumed_inside_the_call(self):
        """faster-whisper decodes while its generator is iterated: an error in the middle must surface from transcribe_chunk."""
        engine = self.loaded()
        self.stack.default_segments = [fseg(0.0, 1.0, " first"), RuntimeError("CUDA error in the second window")]
        with self.assertRaisesRegex(RuntimeError, "second window"):
            engine.transcribe_chunk(self.audio(), "en", None)

    def test_an_empty_chunk_never_reaches_the_model(self):
        engine = self.loaded()
        calls = len(self.stack.model.transcribe_calls)
        self.assertEqual(engine.transcribe_chunk(np.zeros(0, np.float32), "ko", None)["segments"], [])
        self.assertEqual(engine.transcribe_chunk(np.zeros(0, np.float32), None, None)["language"], "en")
        self.assertEqual(len(self.stack.model.transcribe_calls), calls)

    def test_transcribe_chunk_loads_the_model_on_first_use(self):
        engine = self.engine()
        engine.transcribe_chunk(self.audio(), "en", None)
        self.assertEqual(len(self.stack.constructed), 1)
        self.addCleanup(engine.release)

    def test_language_none_goes_through_the_models_own_detection_restricted_to_ko_en(self):
        self.stack.lid = ("ja", 0.55, [("ja", 0.55), ("ko", 0.30), ("en", 0.15)])             # japanese leads overall: the pipeline only has ko, en
        engine = self.loaded()
        result = engine.transcribe_chunk(self.audio(), None, None)
        self.assertEqual(self.last_call()[1]["language"], "ko")
        self.assertEqual(result["language"], "ko")
        self.assertEqual(len(self.stack.model.detect_calls), 1)

    def test_a_given_language_skips_the_detection(self):
        engine = self.loaded()
        engine.transcribe_chunk(self.audio(), "en", None)
        self.assertEqual(self.stack.model.detect_calls, [])


class LanguageIdTests(FwCase):
    def test_probabilities_are_restricted_and_renormalised(self):
        self.stack.lid = ("ja", 0.5, [("ja", 0.5), ("ko", 0.3), ("en", 0.1), ("zh", 0.1)])
        out = self.loaded().detect_languages([np.ones(SR, np.float32)])
        self.assertEqual(out[0]["top"], "ko")
        self.assertAlmostEqual(out[0]["ko"], 0.75)
        self.assertAlmostEqual(out[0]["en"], 0.25)
        self.assertEqual(out[0], asr_engines.restrict_lid({"ja": 0.5, "ko": 0.3, "en": 0.1}, ("ko", "en")))

    def test_the_candidate_languages_are_the_callers(self):
        self.stack.lid = ("ja", 0.5, [("ja", 0.5), ("ko", 0.3), ("en", 0.2)])
        out = self.loaded().detect_languages([np.ones(SR, np.float32)], ("ja", "ko", "en"))
        self.assertEqual(out[0]["top"], "ja")
        self.assertAlmostEqual(sum(out[0][c] for c in ("ja", "ko", "en")), 1.0)

    def test_one_answer_per_clip_and_a_clip_is_cut_at_30_seconds(self):
        engine = self.loaded()
        out = engine.detect_languages([np.ones(SR, np.float32), np.ones(45 * SR, np.float32), np.ones(3 * SR, np.float32)])
        self.assertEqual(len(out), 3)
        self.assertEqual([len(a) for a in self.stack.model.detect_calls], [SR, 30 * SR, 3 * SR])
        self.assertTrue(all(a.dtype == np.float32 for a in self.stack.model.detect_calls))

    def test_an_empty_clip_is_uniform_and_not_sent_to_the_model(self):
        out = self.loaded().detect_languages([np.zeros(0, np.float32)])
        self.assertEqual(out, [{"ko": 0.5, "en": 0.5, "top": "ko"}])
        self.assertEqual(self.stack.model.detect_calls, [])

    def test_an_answer_without_the_probability_list_uses_the_top_language(self):
        self.stack.lid = ("en", 0.8)
        self.assertEqual(self.loaded().detect_languages([np.ones(SR, np.float32)])[0]["top"], "en")
        self.stack.lid = ("en", 0.8, [])
        self.assertEqual(self.loaded().detect_languages([np.ones(SR, np.float32)])[0]["top"], "en")

    def test_a_non_finite_probability_counts_as_zero(self):
        self.stack.lid = ("ko", 0.9, [("ko", float("nan")), ("en", 0.4)])
        self.assertEqual(self.loaded().detect_languages([np.ones(SR, np.float32)])[0]["top"], "en")


# ---------------------------------------------------------------------------------------------- prompt budget, retry, post-filters
VOCAB = parse_vocab_text("Acme\nAcmeScan-CXR\nFDA\n510(k)\nPre-Sub\nHIPAA\nExample Radiology\nAcme = 애크미 | 액미\n")


def vad_result(regions, total):
    return vad.VadResult(regions, "energy", np.full(int(total * 50), -50.0, np.float32), {})


class PromptAndFiltersTests(FwCase):
    def test_the_tokenizer_is_the_models_and_counts_like_faster_whisper_does(self):
        engine = self.loaded()
        tok = engine.tokenizer
        self.assertIs(engine.tokenizer, tok)                                    # built once
        self.assertEqual(tok.encode(" one two three"), [0, 1, 2])
        self.assertEqual(self.stack.model.hf_tokenizer.calls[-1], (" one two three", False))      # no special tokens

    def test_the_140_token_budget_is_counted_with_the_model_tokenizer(self):
        terms = [f"term{i}" for i in range(400)]
        engine = self.loaded()
        prompt = asr.build_asr_prompt(Vocab(terms=terms), engine.tokenizer, asr.ASR_PROMPT_TOKENS, language="ko", frames=engine.prompt_frames)
        self.assertTrue(prompt.startswith(WhisperEngine.prompt_frames["ko"]))
        self.assertLessEqual(len(engine.tokenizer.encode(" " + prompt.strip())), 140)
        self.assertGreater(len(engine.tokenizer.encode(" " + prompt.strip())), 100)          # it filled the budget, it was not cut short
        self.assertEqual(asr.ASR_PROMPT_TOKENS, 140)

    def test_a_looping_chunk_is_retried_without_the_prompt_and_the_better_answer_wins(self):
        looped = [fseg(0.0, 3.0, " la la la la la la", lp=-1.4, cr=3.1)]
        clean = [fseg(0.0, 3.0, " hello there", lp=-0.3, cr=1.1)]
        engine = self.loaded()
        self.stack.script = [looped, clean]
        stats = collections.Counter()
        result = asr.decode_chunk(engine, np.zeros(3 * SR, np.float32), "en", "A medical AI meeting. Terms: FDA", {"fda"}, stats)
        calls = self.stack.model.transcribe_calls[-2:]
        self.assertEqual([c[1]["initial_prompt"] for c in calls], ["A medical AI meeting. Terms: FDA", None])
        self.assertEqual(result["text"], "hello there")
        self.assertEqual((stats["prompt_retries"], stats["retries_accepted"]), (1, 1))

    def test_a_good_chunk_is_decoded_once(self):
        engine = self.loaded()
        self.stack.script = [[fseg(0.0, 2.0, " fine", lp=-0.2)]]
        before = len(self.stack.model.transcribe_calls)
        asr.decode_chunk(engine, np.zeros(2 * SR, np.float32), "en", "Terms: FDA", {"fda"}, collections.Counter())
        self.assertEqual(len(self.stack.model.transcribe_calls) - before, 1)

    def test_the_existing_post_filters_treat_it_like_any_whisper_engine(self):
        """The same segments through transcribe_track from this engine and from a scripted Whisper-like engine give the same track."""
        segments = [(0.1, 2.0, " Acme builds AcmeScan-CXR", -0.25, 0.01, 1.2), (2.2, 3.5, " thank you", -1.8, 0.7, 1.0),
                    (3.6, 5.5, " okay okay okay okay okay okay okay okay", -0.4, 0.02, 3.4), (5.6, 8.0, " the FDA 510(k) review", -0.3, 0.03, 1.3)]

        class Scripted(asr_engines.Engine):
            name = "scripted"
            prompt_frames = WhisperEngine.prompt_frames
            supports_lid = False

            def __init__(self):
                super().__init__("scripted", allow_download=False)

            def load(self):
                pass

            @property
            def tokenizer(self):
                return types.SimpleNamespace(encode=lambda text: text.split())

            def transcribe_chunk(self, audio, language, prompt):
                segs = [{"start": a, "end": b, "text": t.strip(), "avg_logprob": lp, "no_speech_prob": ns, "compression_ratio": cr, "temperature": 0.0}
                        for a, b, t, lp, ns, cr in segments]
                return {"text": " ".join(s["text"] for s in segs), "segments": segs, "language": language,
                        "avg_logprob": float(np.mean([s["avg_logprob"] for s in segs]))}

        self.stack.default_segments = [fseg(a, b, t, lp=lp, ns=ns, cr=cr, temperature=0.0) for a, b, t, lp, ns, cr in segments]
        cfg = Config(support_dir=self.root / "nonexistent-support")
        x = np.zeros(20 * SR, np.float32)
        regions = [(1.0, 9.0)]
        mine = asr.transcribe_track(x, self.loaded(), cfg, VOCAB, track="remote", language="en", vad=vad_result(regions, 20.0))
        # the segment list of FasterWhisperEngine carries no ``supports_lid``-less difference: compare against the scripted engine
        theirs = asr.transcribe_track(x, Scripted(), cfg, VOCAB, track="remote", language="en", vad=vad_result(regions, 20.0))
        self.assertEqual(mine.segments, theirs.segments)
        self.assertEqual(mine.dropped, theirs.dropped)
        self.assertTrue(mine.dropped)                                                          # the filters did something
        self.assertTrue(mine.segments)


# ---------------------------------------------------------------------------------------------- release
class ReleaseTests(FwCase):
    def test_release_frees_the_model_and_the_tokenizer(self):
        engine = self.loaded()
        _ = engine.tokenizer
        model = self.stack.model
        engine.release()
        self.assertEqual(self.stack.unloaded, [model])
        self.assertIsNone(engine._model)
        self.assertIsNone(engine._tokenizer)
        self.assertEqual((engine.active_device, engine.active_compute_type), (None, None))
        engine.release()                                                         # twice is fine
        self.assertEqual(len(self.stack.unloaded), 1)

    def test_release_swallows_an_unload_error(self):
        engine = self.loaded()
        self.stack.model.model.unload_model = mock.Mock(side_effect=RuntimeError("device lost"))
        engine.release()
        self.assertIsNone(engine._model)

    def test_a_released_engine_loads_again_from_the_resolved_path(self):
        engine = self.loaded()
        engine.release()
        engine.transcribe_chunk(np.zeros(SR, np.float32), "en", None)
        self.assertEqual(len(self.stack.constructed), 2)
        self.assertEqual(self.stack.constructed[0][0], self.stack.constructed[1][0])
        self.addCleanup(engine.release)

    def test_a_released_model_is_garbage(self):
        engine = self.loaded()
        engine.release()
        with mock.patch.object(engine, "load", lambda: None), self.assertRaisesRegex(EngineUnavailable, "released"):
            engine.transcribe_chunk(np.zeros(SR, np.float32), "en", None)


# ---------------------------------------------------------------------------------------------- check and fetch
class CommandTests(FwCase):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fwmod.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_check_reports_everything_and_downloads_nothing(self):
        hub = FakeHub(cached=None, downloaded="/never")
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
            code, out, _err = self.run_main("check", "--model", str(self.model_dir), "--device", "auto")
        self.assertEqual(code, 0, out)
        for needle in ("ok   faster_whisper: 1.1.1-fake", "ok   ctranslate2: 4.5.0-fake, 1 CUDA device(s)", "ok   runtime: cuda / float16",
                       f"ok   model: {self.model_dir}: {self.model_dir}"):
            self.assertIn(needle, out)
        self.assertEqual(self.stack.constructed, [])                              # no --load: the model is not started
        self.assertEqual(hub.calls, [])

    def test_check_load_starts_the_model_and_frees_it(self):
        code, out, _err = self.run_main("check", "--model", str(self.model_dir), "--load")
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"ok   load: started on cuda \(float16\) in [0-9.]+ s")
        self.assertEqual(len(self.stack.unloaded), 1)

    def test_check_load_failure_is_fail_and_exit_1(self):
        self.stack.first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        code, out, _err = self.run_main("check", "--model", str(self.model_dir), "--device", "cuda", "--load")
        self.assertEqual(code, 1)
        self.assertRegex(out, r"FAIL load: EngineUnavailable: .*libcudnn_ops")

    def test_check_load_failure_inside_the_lazy_generator_is_fail_and_exit_1(self):
        self.stack.lazy_first_call_errors["cuda"] = RuntimeError("Could not load library libcudnn_ops.so.9")
        code, out, _err = self.run_main("check", "--model", str(self.model_dir), "--device", "cuda", "--load")
        self.assertEqual(code, 1)
        self.assertRegex(out, r"FAIL load: EngineUnavailable: .*libcudnn_ops")
        self.assertEqual(len(self.stack.unloaded), 1)

    def test_check_without_the_package(self):
        with mock.patch.dict(sys.modules, {"faster_whisper": None}):
            code, out, _err = self.run_main("check", "--model", str(self.model_dir))
        self.assertEqual(code, 1)
        self.assertIn("FAIL faster_whisper: faster-whisper cannot be imported", out)
        self.assertIn("requirements-server.txt", out)

    def test_check_with_a_model_that_is_not_there_says_how_to_fetch_it(self):
        hub = FakeHub(cached=None)
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
            code, out, _err = self.run_main("check")
        self.assertEqual(code, 1)
        self.assertIn("FAIL model: ", out)
        self.assertIn("fetch --yes", out)
        self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True)])      # only the local-only lookup

    def test_check_with_a_bad_model_name_is_an_error_not_a_traceback(self):
        code, out, err = self.run_main("check", "--model", "mlx-community/whisper-large-v3-mlx")
        self.assertEqual(code, 1)
        self.assertIn("MLX model", err)

    def test_fetch_needs_yes_and_does_nothing_without_it(self):
        hub = FakeHub(cached=None, downloaded=str(self.model_dir))
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
            code, _out, err = self.run_main("fetch")
        self.assertEqual(code, 2)
        self.assertIn("add --yes", err)
        self.assertEqual(hub.calls, [])

    def test_fetch_refuses_while_hf_hub_offline_is_set(self):
        hub = FakeHub(cached=None, downloaded=str(self.model_dir))
        with mock.patch.dict(os.environ, {"HF_HUB_OFFLINE": "1"}), mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}):
            code, _out, err = self.run_main("fetch", "--yes")
        self.assertEqual(code, 1)
        self.assertIn("HF_HUB_OFFLINE", err)
        self.assertEqual(hub.calls, [])

    def test_fetch_yes_downloads_once_and_prints_the_path(self):
        hub = FakeHub(cached=None, downloaded=str(self.model_dir))
        with mock.patch.dict(sys.modules, {"huggingface_hub": hub.module}), self.assertLogs("mcap.asr", "WARNING"):
            code, out, _err = self.run_main("fetch", "--yes", "--model", "large-v3")
        self.assertEqual((code, out.strip()), (0, str(self.model_dir)))
        self.assertEqual(hub.calls, [("Systran/faster-whisper-large-v3", True), ("Systran/faster-whisper-large-v3", False)])


# ---------------------------------------------------------------------------------------------- a request through the real server core
class ServerIntegrationTests(FwCase):
    """The real ``asr_server`` core with this engine (built by the real ``default_backend_factory``) over the fake stack: no socket."""

    def setUp(self):
        super().setUp()
        self.secrets, self.logs = self.root / "secrets", self.root / "logs"
        for directory in (self.secrets, self.logs):
            directory.mkdir()
            os.chmod(directory, 0o700)
        cfg = S.config_from_dict({"secrets_dir": str(self.secrets), "log_dir": str(self.logs), "backend": "faster-whisper",
                                  "model": str(self.model_dir), "backend_options": {"device": "cuda", "compute_type": "float16", "beam_size": 3}})
        quiet = logging.NullHandler()
        logging.getLogger("mcap.asr_server").addHandler(quiet)
        self.addCleanup(logging.getLogger("mcap.asr_server").removeHandler, quiet)
        self.state = S.ServerState(cfg, S.default_backend_factory(cfg)).start()
        self.addCleanup(self.state.close)
        self.token, _row = self.state.tokens.issue("mic", time.time(), 90)

    def call(self, method, path, body=b"", headers=None):
        h = {"X-MCAP-Proto": S.PROTO, "Authorization": f"Bearer {self.token}"}
        if method in ("POST", "PUT"):
            h["Content-Length"] = str(len(body))
        h.update(headers or {})
        status, hdrs, raw = S.handle_request(self.state, method, path, h, body, time.time())
        return status, (json.loads(raw.decode("utf-8")) if raw else None)

    def pcm(self, samples):
        return np.full(samples, 300, dtype="<i2").tobytes()

    def test_the_backend_was_loaded_by_the_server_and_health_describes_it(self):
        self.assertEqual(len(self.stack.constructed), 1)
        status, health = self.call("GET", "/v1/health?detail=1")
        self.assertEqual(status, 200)
        self.assertEqual((health["engine"], health["kind"], health["supports_lid"], health["confidence"]),
                         ("faster-whisper", "server", True, "logprob"))
        self.assertEqual(health["model"], str(self.model_dir))

    def test_a_chunk_with_vocabulary_reaches_initial_prompt_and_comes_back_with_log_probs(self):
        terms = ["Acme", "AcmeScan-CXR", "FDA"]
        status, _ = self.call("PUT", "/v1/vocab/" + S.canonical_vocab_digest({"terms": terms}), S._dumps({"terms": terms}),
                              {"Content-Type": "application/json"})
        self.assertIn(status, (200, 201, 204))
        self.stack.script = [[fseg(0.1, 1.9, " hello Acme", lp=-0.21, ns=0.02, cr=1.2, temperature=0.0)]]
        body = self.pcm(2 * SR)
        status, answer = self.call("POST", "/v1/chunk", body, {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(2 * SR),
                                                              "X-MCAP-Lang": "ko", "X-MCAP-Prompt": "frame+list",
                                                              "X-MCAP-Vocab": S.canonical_vocab_digest({"terms": terms})})
        self.assertEqual(status, 200, answer)
        _audio, kwargs = self.stack.model.transcribe_calls[-1]
        self.assertTrue(kwargs["initial_prompt"].startswith(WhisperEngine.prompt_frames["ko"]))
        for term in terms:
            self.assertIn(term, kwargs["initial_prompt"])
        self.assertEqual((kwargs["language"], kwargs["beam_size"], kwargs["vad_filter"]), ("ko", 3, False))
        self.assertEqual(answer["prompt_text"], kwargs["initial_prompt"])
        self.assertEqual((answer["engine"], answer["language"], answer["text"]), ("faster-whisper", "ko", "hello Acme"))
        self.assertEqual(answer["segments"][0]["avg_logprob"], -0.21)
        self.assertEqual(answer["segments"][0]["no_speech_prob"], 0.02)

    def test_language_auto_uses_the_models_language_id(self):
        self.stack.lid = ("en", 0.97, [("en", 0.97), ("ko", 0.02), ("ja", 0.01)])
        body = self.pcm(SR)
        status, answer = self.call("POST", "/v1/chunk", body, {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(SR), "X-MCAP-Lang": "auto"})
        self.assertEqual(status, 200, answer)
        self.assertEqual(self.stack.model.transcribe_calls[-1][1]["language"], "en")
        self.assertEqual(answer["language"], "en")

    def test_the_lid_endpoint_runs_the_models_detection_per_clip(self):
        self.stack.lid = ("ko", 0.9, [("ko", 0.9), ("en", 0.1)])
        status, answer = self.call("POST", "/v1/lid", self.pcm(3 * SR), {"Content-Type": "application/octet-stream",
                                                                          "X-MCAP-Clips": f"{SR},{2 * SR}", "X-MCAP-Langs": "ko,en"})
        self.assertEqual(status, 200, answer)
        self.assertEqual([r["top"] for r in answer["results"]], ["ko", "ko"])
        self.assertEqual([len(a) for a in self.stack.model.detect_calls], [SR, 2 * SR])

    def test_no_audio_or_text_is_left_in_the_server_directories(self):
        self.stack.script = [[fseg(0.1, 1.0, " CANARY-TRANSCRIPT-w5d")]]
        self.call("POST", "/v1/chunk", self.pcm(SR), {"Content-Type": "application/octet-stream", "X-MCAP-Samples": str(SR), "X-MCAP-Lang": "en"})
        for root in (self.secrets, self.logs):
            for path in root.rglob("*"):
                if path.is_file():
                    self.assertNotIn(b"CANARY-TRANSCRIPT-w5d", path.read_bytes(), path)
        self.assertEqual([f for f in S.scan_for_audio(self.logs) if f.kind.startswith("audio-")], [])


# ---------------------------------------------------------------------------------------------- requirements and wiring
class RequirementsTests(unittest.TestCase):
    def lines(self, name):
        return [ln.strip() for ln in (PIPELINE / name).read_text(encoding="utf-8").splitlines() if ln.strip() and not ln.lstrip().startswith("#")]

    def test_the_server_file_pins_the_three_packages_exactly(self):
        pins = {ln.split("==")[0].lower(): ln.split("==")[1] for ln in self.lines("requirements-server.txt") if "==" in ln}
        self.assertEqual(set(pins), {"faster-whisper", "ctranslate2", "numpy"})
        for name, version in pins.items():
            self.assertRegex(version, r"^\d+(\.\d+)+$", name)
        self.assertEqual([ln for ln in self.lines("requirements-server.txt") if "==" not in ln], [])         # nothing unpinned, no URL, no option

    def test_the_client_lock_and_setup_do_not_know_the_server_packages(self):
        client = (PIPELINE / "requirements.lock.txt").read_text(encoding="utf-8").lower()
        for name in ("faster-whisper", "faster_whisper", "ctranslate2", "onnxruntime", "tokenizers", "requirements-server"):
            self.assertNotIn(name, client, name)
        for script in ("setup_python.sh", "install.sh", "build_app.sh"):
            path = REPO / "scripts" / script
            if path.exists():
                self.assertNotIn("requirements-server", path.read_text(encoding="utf-8"), script)
        makefile = REPO / "Makefile"
        if makefile.exists():
            self.assertNotIn("requirements-server", makefile.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------------------------- the Linux installer's shell tests
class InstallerShellTests(unittest.TestCase):
    """Runs scripts/asr_server/test_install_server_linux.sh (hermetic: stub systemctl, useradd, groupadd, python, chown; a temp HOME)."""

    SCRIPT = REPO / "scripts" / "asr_server" / "test_install_server_linux.sh"

    def test_the_files_exist_and_are_valid_bash(self):
        for name in ("install_server_linux.sh", "test_install_server_linux.sh"):
            path = REPO / "scripts" / "asr_server" / name
            self.assertTrue(os.access(path, os.X_OK), f"{name} is not executable")
            result = subprocess.run(["/bin/bash", "-n", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((REPO / "scripts" / "asr_server" / "mcap-asr.service.template").is_file())

    @unittest.skipUnless(os.path.exists("/bin/bash"), "no /bin/bash")
    def test_the_shell_tests_pass(self):
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("HOME", "/"), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PYTHONDONTWRITEBYTECODE": "1"}
        result = subprocess.run(["/bin/bash", str(self.SCRIPT)], env=env, capture_output=True, text=True, timeout=600)
        tail = "\n".join(result.stdout.splitlines()[-25:])
        self.assertEqual(result.returncode, 0, tail + result.stderr[-500:])
        self.assertRegex(result.stdout, r"install_server_linux tests: \d+ passed, 0 failed")


if __name__ == "__main__":
    unittest.main()
