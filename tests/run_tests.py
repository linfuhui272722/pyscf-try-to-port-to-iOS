#!/usr/bin/env python3
"""Run every Python test in this directory without needing pytest.

``python -m pytest tests -v`` works too when pytest is installed, but the build
host images here do not have it, so this keeps the suite runnable with a bare
interpreter.

    python tests/run_tests.py

Each module runs in its own interpreter: test_shims deliberately rewrites
``sys.path`` to put the vendored shims ahead of the real packages, and that
global state leaks into test_engine if both share a process.
"""

from __future__ import annotations

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODULES = [
    "test_engine.py",
    "test_geomopt.py",
    "test_shims.py",
    "test_threads.py",
    "test_mayer.py",
    "test_charge_spin.py",
    "test_nbo.py",
    "test_localized_orbitals.py",
    "test_orbital_localization.py",
    "test_orbital_surface.py",
    "test_density_surface.py",
    "test_core_orbitals.py",
]

# Imports the module and calls every top-level test_* function, in one process.
HARNESS = r"""
import importlib.util, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location("suite", path)
module = importlib.util.module_from_spec(spec)
sys.modules["suite"] = module
spec.loader.exec_module(module)
tests = [(n, f) for n, f in sorted(vars(module).items())
         if n.startswith("test_") and callable(f)]
failed = 0
for name, fn in tests:
    try:
        fn()
    except Exception as exc:
        failed += 1
        print(f"  FAIL {name}: {type(exc).__name__}: {exc}")
    else:
        print(f"  ok   {name}")
print(f"__SUMMARY__ {len(tests) - failed} {len(tests)}")
sys.exit(1 if failed else 0)
"""


def main() -> int:
    passed = total = 0
    for filename in MODULES:
        path = os.path.join(HERE, filename)
        print(f"\n{filename}")
        result = subprocess.run(
            [sys.executable, "-c", HARNESS, path],
            capture_output=True, text=True, cwd=HERE,
        )
        for line in result.stdout.splitlines():
            if line.startswith("__SUMMARY__"):
                _, ok, count = line.split()
                passed += int(ok)
                total += int(count)
            else:
                print(line)
        if result.stderr.strip():
            print(result.stderr.rstrip())

    print(f"\n{passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
