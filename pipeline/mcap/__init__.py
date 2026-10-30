"""mcap - the Catch Everything post-processing pipeline (transcribe -> note -> publish). See SPEC.md."""
import sys
import types

# 0.2.0 (SPEC 18): the lane gates exist, so the Swift app's pre-launch contract check ("a pipeline that honours local_only
# and the organisation policy") is true from this version on. The app refuses to start an older pipeline for a policy-managed Mac or a
# local-only meeting; the personal install without a policy runs with any version.
__version__ = "0.2.0"


class _Package(types.ModuleType):
    """Keeps ``mcap.lanes`` out of the package namespace: the attribute is looked up in ``sys.modules`` on every access instead.

    Why: ``asr_router._lane_gate`` does ``from . import lanes`` at call time and its tests replace the lane module through ``sys.modules``
    (``{"mcap.lanes": None}`` = 'the lane module is not there', a stand-in module with a ``gate``). Python's import system stores a
    submodule as an attribute of its package, and ``from . import x`` prefers that attribute to ``sys.modules``, so once ``note`` has
    imported the real module (it does, at import) such a replacement would be ignored. With this class ``mcap.lanes`` always names
    what ``sys.modules["mcap.lanes"]`` holds right now: the real module, a stand-in, or nothing (None: AttributeError, and
    ``from . import lanes`` then fails the way a missing module does). Every other name behaves as in any package."""

    def __setattr__(self, name, value):
        if name == "lanes" and isinstance(value, types.ModuleType):      # the import system's own bookkeeping: not stored
            return
        super().__setattr__(name, value)

    def __getattr__(self, name):
        if name == "lanes":
            module = sys.modules.get(f"{__name__}.lanes")
            if module is not None:
                return module
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


sys.modules[__name__].__class__ = _Package
