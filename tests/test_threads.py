"""Tests for the OpenMP thread setting exposed to the UI.

The real PySCF extensions will not load on the build host, so these tests
install a stub ``pyscf.lib`` that records what ``omp_set_num_threads`` was
called with.  That keeps the engine's own logic — validation, the override
bookkeeping, and the "automatic" branch — under test even though the runtime
itself can only be exercised on a device.
"""

from __future__ import annotations

import os
import sys
import types

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf_mobile import engine  # noqa: E402


class _StubLib:
    """Stands in for ``pyscf.lib``, recording the last thread count set."""

    def __init__(self, cores: int):
        self.cores = cores
        self.current = cores
        self.calls: list[int] = []

    def num_threads(self, n=None):
        if n is not None:
            self.current = int(n)
            self.calls.append(int(n))
        return self.current


def _install_stub(cores: int | None = None) -> _StubLib:
    """Point ``pyscf.lib`` at a stub, and undo it on the way out.

    ``engine.num_threads`` reaches the runtime with ``from pyscf import lib``,
    so the stub has to be registered in ``sys.modules`` rather than patched onto
    ``engine.pyscf``: the import system looks the name up in the module table,
    not on the engine's attribute.  ``engine.pyscf`` is set too so the
    availability guard passes.
    """
    lib = _StubLib(cores if cores is not None else (os.cpu_count() or 1))
    module = types.ModuleType("pyscf")
    module.lib = lib
    sys.modules["pyscf"] = module
    sys.modules["pyscf.lib"] = lib
    engine.pyscf = module
    engine._THREADS = None
    return lib


def _restore() -> None:
    sys.modules.pop("pyscf", None)
    sys.modules.pop("pyscf.lib", None)
    engine.pyscf = None
    engine._THREADS = None


def test_set_and_read_thread_count():
    lib = _install_stub()
    try:
        result = engine.num_threads(4)
        assert result["threads"] == 4
        assert result["override"] == 4
        assert lib.calls == [4], lib.calls
        assert lib.current == 4

        # Reading back reports the value that was set.
        again = engine.num_threads()
        assert again["threads"] == 4
        assert again["override"] == 4
        assert lib.calls == [4], "reading must not set anything"
    finally:
        _restore()


def test_zero_restores_the_core_count():
    lib = _install_stub()
    try:
        engine.num_threads(2)
        assert engine.num_threads()["threads"] == 2

        restored = engine.num_threads(0)
        # 0 means "automatic", so the override clears and the runtime is handed
        # the core count rather than the previous override.
        assert restored["override"] is None
        assert restored["threads"] == os.cpu_count()
        assert restored["cores"] == os.cpu_count()
        assert lib.calls == [2, os.cpu_count()], lib.calls
    finally:
        _restore()


def test_out_of_range_counts_are_rejected():
    lib = _install_stub()
    try:
        for bad in (-1, engine.MAX_THREADS + 1):
            try:
                engine.num_threads(bad)
            except ValueError:
                pass
            else:
                raise AssertionError(f"{bad} should have been rejected")
        # A rejected value must not have reached the runtime or the override.
        assert lib.calls == [], lib.calls
        assert engine._THREADS is None
    finally:
        _restore()


def test_dispatch_routes_the_thread_method():
    _install_stub()
    try:
        assert engine.dispatch("threads", {"threads": 3})["threads"] == 3
        assert engine.dispatch("threads", {})["threads"] == 3
    finally:
        _restore()


def test_status_reports_the_override_separately():
    _install_stub()
    try:
        engine.num_threads(6)
        status = engine.engine_status()
        # ``threads`` is what the runtime reports; ``threadOverride`` is the
        # user's choice. The UI needs them apart to show "automatic".
        assert status["threadOverride"] == 6
        assert status["threads"] == 6
        assert status["cores"] == os.cpu_count()

        engine.num_threads(0)
        status = engine.engine_status()
        assert status["threadOverride"] is None
    finally:
        _restore()


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def run_all() -> int:
    failures = 0
    for fn in TESTS:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except Exception as exc:
            failures += 1
            print(f"  FAIL {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(TESTS) - failures}/{len(TESTS)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(run_all())
